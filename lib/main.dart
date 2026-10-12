import 'dart:convert';
import 'dart:math';
import 'dart:html' as html;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var supabaseUrl = const String.fromEnvironment('SUPABASE_URL').trim();
  final supabaseAnonKey = const String.fromEnvironment('SUPABASE_ANON_KEY').trim();

  if (supabaseUrl.endsWith('/')) {
    supabaseUrl = supabaseUrl.substring(0, supabaseUrl.length - 1);
  }
  if (supabaseUrl.endsWith('/rest/v1')) {
    supabaseUrl = supabaseUrl.replaceAll('/rest/v1', '');
  }

  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  await AppState.instance.loadSavedPreferences();

  runApp(const CorpHubApp());
}

// ----------------- إدارة اللغات والمظهر -----------------
class AppState extends ChangeNotifier {
  static final AppState instance = AppState._();
  AppState._();

  bool isArabic = true;
  ThemeMode themeMode = ThemeMode.dark;

  Future<void> loadSavedPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey('app_is_arabic')) {
        isArabic = prefs.getBool('app_is_arabic') ?? true;
      }
      if (prefs.containsKey('app_is_dark')) {
        final isDark = prefs.getBool('app_is_dark') ?? true;
        themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
      }
    } catch (_) {}
  }

  void toggleLanguage() async {
    isArabic = !isArabic;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('app_is_arabic', isArabic);
    } catch (_) {}
  }

  void toggleTheme() async {
    themeMode = themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('app_is_dark', themeMode == ThemeMode.dark);
    } catch (_) {}
  }

  String t(String en, String ar) => isArabic ? ar : en;
}

class CorpHubApp extends StatelessWidget {
  const CorpHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppState.instance,
      builder: (context, _) {
        final state = AppState.instance;
        const eglNavyDark = Color(0xFF0F172A);
        const eglNavyCard = Color(0xFF1E293B);
        const eglBlueAccent = Color(0xFF0284C7);

        return MaterialApp(
          title: state.isArabic ? 'دليل الشركات' : 'CorpHub - EGL',
          debugShowCheckedModeBanner: false,
          themeMode: state.themeMode,
          theme: ThemeData(
            brightness: Brightness.light,
            scaffoldBackgroundColor: const Color(0xFFF1F5F9),
            primaryColor: const Color(0xFF0284C7),
            cardColor: Colors.white,
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF0284C7),
              secondary: Color(0xFF0EA5E9),
              surface: Colors.white,
            ),
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            scaffoldBackgroundColor: eglNavyDark,
            primaryColor: eglBlueAccent,
            cardColor: eglNavyCard,
            colorScheme: const ColorScheme.dark(
              primary: eglBlueAccent,
              secondary: Color(0xFF38BDF8),
              surface: eglNavyCard,
            ),
          ),
          home: Directionality(
            textDirection: state.isArabic ? TextDirection.rtl : TextDirection.ltr,
            child: const MainHomeScreen(),
          ),
        );
      },
    );
  }
}

// ----------------- الشاشة الرئيسية -----------------
class MainHomeScreen extends StatefulWidget {
  const MainHomeScreen({super.key});

  @override
  State<MainHomeScreen> createState() => _MainHomeScreenState();
}

class _MainHomeScreenState extends State<MainHomeScreen> {
  Map<String, dynamic>? _currentUser;
  bool _loading = true;
  String _searchQuery = '';
  List<Map<String, dynamic>> _companies = [];
  Map<String, dynamic>? _selectedCompanyForPanel;
  
  double _leftPaneWidth = 360.0;

  RealtimeChannel? _companiesChannel;
  RealtimeChannel? _userSessionChannel;

  final Map<String, bool> _privacy = {
    'allow_public_read': true,
    'public_show_tax_card': false,
    'public_show_phones': false,
    'public_show_operation_addresses': false,
    'public_show_mailing_addresses': true,
    'public_show_relations': true,
  };

  @override
  void initState() {
    super.initState();
    _checkSavedSessionAndLoad();
    _setupRealtime();
  }

  @override
  void dispose() {
    if (_companiesChannel != null) {
      Supabase.instance.client.removeChannel(_companiesChannel!);
    }
    if (_userSessionChannel != null) {
      Supabase.instance.client.removeChannel(_userSessionChannel!);
    }
    super.dispose();
  }

  void _setupRealtime() {
    _companiesChannel = Supabase.instance.client
        .channel('public:companies_feed')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'companies',
          callback: (_) => _fetchCompanies(quiet: true),
        )
        .subscribe();

    _userSessionChannel = Supabase.instance.client
        .channel('public:user_sync')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'app_users',
          callback: (payload) async {
            if (_currentUser != null) {
              final updatedId = payload.newRecord['id'] ?? payload.oldRecord['id'];
              if (updatedId == _currentUser!['id']) {
                if (payload.eventType == PostgresChangeEvent.delete || payload.newRecord['is_active'] == false) {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.remove('saved_user_session');
                  if (mounted) {
                    setState(() => _currentUser = null);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(AppState.instance.t('Your session was revoked by administrator.', 'تم إنهاء جلستك من قِبل الإدارة.'))),
                    );
                  }
                } else if (payload.eventType == PostgresChangeEvent.update) {
                  setState(() => _currentUser = Map<String, dynamic>.from(payload.newRecord));
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('saved_user_session', jsonEncode(_currentUser));
                }
              }
            }
          },
        )
        .subscribe();
  }

  Future<void> _checkSavedSessionAndLoad() async {
    setState(() => _loading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUserStr = prefs.getString('saved_user_session');
      if (savedUserStr != null) {
        _currentUser = jsonDecode(savedUserStr);
      }
    } catch (_) {}

    await _fetchSettings();
    await _fetchCompanies();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);
    await _fetchSettings();
    await _fetchCompanies();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _fetchSettings() async {
    try {
      final res = await Supabase.instance.client.from('system_settings').select();
      for (var row in res) {
        final key = row['key'] as String;
        final val = row['value'];
        if (_privacy.containsKey(key)) {
          _privacy[key] = val == true || val == 'true';
        }
      }
    } catch (_) {}
  }

  Future<void> _fetchCompanies({bool quiet = false}) async {
    try {
      final res = await Supabase.instance.client
          .from('companies')
          .select('*, company_addresses(*), company_contacts(*)')
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() {
          _companies = List<Map<String, dynamic>>.from(res);
          if (!quiet) _loading = false;
        });
      }
    } catch (_) {}
  }

  bool get _canEdit {
    if (_currentUser == null) return false;
    final r = _currentUser!['role'];
    return r == 'admin' || r == 'editor';
  }

  Future<void> _deleteSingleCompany(Map<String, dynamic> company) async {
    final s = AppState.instance;
    final name = s.isArabic
        ? (company['name_ar'] ?? company['name_en'] ?? '')
        : (company['name_en'] ?? company['name_ar'] ?? '');

    final confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Directionality(
        textDirection: s.isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(s.t('Delete Company', 'حذف الشركة')),
          content: Text(
            s.t('Are you sure you want to delete "$name"?', 'هل أنت متأكد من حذف شركة "$name"؟'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(s.t('Cancel', 'إلغاء')),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(s.t('Delete', 'حذف')),
            ),
          ],
        ),
      ),
    );

    if (confirm == true) {
      setState(() => _loading = true);
      try {
        final compId = company['id'];
        await Supabase.instance.client.from('company_contacts').delete().eq('company_id', compId);
        await Supabase.instance.client.from('company_addresses').delete().eq('company_id', compId);
        await Supabase.instance.client.from('companies').delete().eq('id', compId);

        if (mounted) {
          setState(() => _selectedCompanyForPanel = null);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s.t('Company deleted', 'تم حذف الشركة بنجاح'))),
          );
        }
        _loadAll();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
          setState(() => _loading = false);
        }
      }
    }
  }

  void _openLoginDialog() async {
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: true,
      builder: (_) => Directionality(
        textDirection: AppState.instance.isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: const GlassLoginDialog(),
      ),
    );
    if (res != null) {
      setState(() => _currentUser = res);
    }
  }

  void _openAddEditCompanyDialog([Map<String, dynamic>? company]) async {
    final isMobile = MediaQuery.of(context).size.width < 768;

    final res = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (_) => Directionality(
        textDirection: AppState.instance.isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: AdvancedCompanyDialog(
          company: company,
          allCompanies: _companies,
          isMobile: isMobile,
          onDeleteRequested: company != null ? () => _deleteSingleCompany(company) : null,
        ),
      ),
    );
    if (res == true) _loadAll();
  }

  void _viewTaxCardImage(String? url, String companyName) {
    final s = AppState.instance;
    if (_currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.t('Please login to view tax card', 'برجاء تسجيل الدخول لعرض البطاقة الضريبية'))),
      );
      _openLoginDialog();
      return;
    }

    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.t('No tax card uploaded', 'لا توجد صورة مسجلة'))),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Directionality(
        textDirection: s.isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 600, maxHeight: 600),
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${s.t("Tax Card - ", "البطاقة الضريبية - ")} $companyName',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                  ],
                ),
                const Divider(),
                Expanded(
                  child: InteractiveViewer(
                    child: url.toLowerCase().contains('.pdf')
                        ? const Center(child: Icon(Icons.picture_as_pdf, size: 64, color: Colors.redAccent))
                        : Image.network(url, fit: BoxFit.contain),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _shareTaxCardAsImage(String? url, String companyName) async {
    final s = AppState.instance;
    if (_currentUser == null || url == null || url.trim().isEmpty) return;

    final msg = '${s.t("Tax Card Document for:", "مستند البطاقة الضريبية لشركة:")} $companyName\n\n$url';
    final wa = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(msg)}');
    if (await canLaunchUrl(wa)) {
      await launchUrl(wa, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final isLoggedIn = _currentUser != null;
    final canBrowse = (_privacy['allow_public_read'] ?? true) || isLoggedIn;
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    final filtered = _companies.where((c) {
      final nameAr = (c['name_ar'] ?? '').toString().toLowerCase();
      final nameEn = (c['name_en'] ?? '').toString().toLowerCase();
      final q = _searchQuery.toLowerCase();
      return nameAr.contains(q) || nameEn.contains(q);
    }).toList();

    filtered.sort((a, b) {
      final strA = s.isArabic
          ? (a['name_ar']?.toString().trim().isNotEmpty == true ? a['name_ar'] : a['name_en'] ?? '')
          : (a['name_en']?.toString().trim().isNotEmpty == true ? a['name_en'] : a['name_ar'] ?? '');

      final strB = s.isArabic
          ? (b['name_ar']?.toString().trim().isNotEmpty == true ? b['name_ar'] : b['name_en'] ?? '')
          : (b['name_en']?.toString().trim().isNotEmpty == true ? b['name_en'] : b['name_ar'] ?? '');

      return strA.toString().toLowerCase().compareTo(strB.toString().toLowerCase());
    });

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF0284C7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('CorpHub', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white)),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.language, size: 20),
            onPressed: () {
              s.toggleLanguage();
              setState(() {});
            },
          ),
          IconButton(
            icon: Icon(s.themeMode == ThemeMode.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 20),
            onPressed: () => s.toggleTheme(),
          ),
          const SizedBox(width: 8),
          if (!isLoggedIn)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
                icon: const Icon(Icons.login, size: 16),
                label: Text(s.t('Login', 'دخول'), style: const TextStyle(fontWeight: FontWeight.bold)),
                onPressed: _openLoginDialog,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: PopupMenuButton<String>(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 12,
                        backgroundColor: const Color(0xFF0284C7),
                        child: Text((_currentUser!['username'] ?? 'U')[0].toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 11)),
                      ),
                      const SizedBox(width: 8),
                      Text(_currentUser!['username'] ?? 'User', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    ],
                  ),
                ),
                onSelected: (val) async {
                  if (val == 'logout') {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.remove('saved_user_session');
                    setState(() => _currentUser = null);
                  }
                },
                itemBuilder: (ctx) => [
                  PopupMenuItem(value: 'logout', child: Text(s.t('Logout', 'تسجيل الخروج'))),
                ],
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: _canEdit
          ? FloatingActionButton.extended(
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_business),
              label: Text(s.t('Add Company', 'إضافة شركة')),
              onPressed: () => _openAddEditCompanyDialog(),
            )
          : null,
      body: !canBrowse
          ? Center(child: Text(s.t('Browsing restricted to members', 'التصفح مغلق لغير المسجلين')))
          : Row(
              children: [
                // 1. القائمة اليسرى لقائمة الشركات (Modern Card Tiles)
                SizedBox(
                  width: isDesktop ? _leftPaneWidth : MediaQuery.of(context).size.width,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: s.t('Search company...', 'ابحث عن شركة...'),
                            prefixIcon: const Icon(Icons.search, size: 20),
                            filled: true,
                            contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                          ),
                          onChanged: (val) => setState(() => _searchQuery = val),
                        ),
                      ),
                      Expanded(
                        child: _loading
                            ? const Center(child: CircularProgressIndicator())
                            : ListView.separated(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                itemCount: filtered.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 8),
                                itemBuilder: (ctx, i) {
                                  final comp = filtered[i];
                                  final isSelected = _selectedCompanyForPanel?['id'] == comp['id'];

                                  return ModernCompanyCardTile(
                                    company: comp,
                                    isSelected: isSelected,
                                    onTap: () {
                                      if (isDesktop) {
                                        setState(() => _selectedCompanyForPanel = comp);
                                      } else {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => MobileCompanyDetailScreen(
                                              company: comp,
                                              allCompanies: _companies,
                                              isLoggedIn: isLoggedIn,
                                              canEdit: _canEdit,
                                              privacy: _privacy,
                                              onEdit: () => _openAddEditCompanyDialog(comp),
                                              onDelete: () => _deleteSingleCompany(comp),
                                              onViewTaxCard: () => _viewTaxCardImage(comp['tax_card_url'], s.isArabic ? (comp['name_ar'] ?? '') : (comp['name_en'] ?? '')),
                                              onShare: () => _shareTaxCardAsImage(comp['tax_card_url'], s.isArabic ? (comp['name_ar'] ?? '') : (comp['name_en'] ?? '')),
                                            ),
                                          ),
                                        );
                                      }
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                
                // 2. الفاصل التفاعلي لتعديل الحجم
                if (isDesktop) ...[
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragUpdate: (details) {
                      setState(() {
                        _leftPaneWidth = (_leftPaneWidth + details.delta.dx).clamp(280.0, 550.0);
                      });
                    },
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeLeftRight,
                      child: Container(
                        width: 6,
                        color: Colors.transparent,
                        child: Center(
                          child: Container(
                            width: 2,
                            height: 36,
                            decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(4)),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 3. اللوحة اليمنى لعرض البيانات (Modern Dashboard View)
                  Expanded(
                    child: _selectedCompanyForPanel == null
                        ? Center(
                            child: Text(
                              s.t('Select a company to view details', 'اختر شركة لعرض التفاصيل'),
                              style: TextStyle(color: Colors.grey.shade500),
                            ),
                          )
                        : DesktopSidePanel(
                            company: _selectedCompanyForPanel!,
                            allCompanies: _companies,
                            isLoggedIn: isLoggedIn,
                            canEdit: _canEdit,
                            privacy: _privacy,
                            onEdit: () => _openAddEditCompanyDialog(_selectedCompanyForPanel),
                            onDelete: () => _deleteSingleCompany(_selectedCompanyForPanel!),
                            onViewTaxCard: () => _viewTaxCardImage(
                              _selectedCompanyForPanel!['tax_card_url'],
                              s.isArabic ? (_selectedCompanyForPanel!['name_ar'] ?? '') : (_selectedCompanyForPanel!['name_en'] ?? ''),
                            ),
                            onShare: () => _shareTaxCardAsImage(
                              _selectedCompanyForPanel!['tax_card_url'],
                              s.isArabic ? (_selectedCompanyForPanel!['name_ar'] ?? '') : (_selectedCompanyForPanel!['name_en'] ?? ''),
                            ),
                            onClose: () => setState(() => _selectedCompanyForPanel = null),
                          ),
                  ),
                ],
              ],
            ),
    );
  }
}

// ----------------- كارت الشركة المودرن القائم على اليسار -----------------
class ModernCompanyCardTile extends StatelessWidget {
  final Map<String, dynamic> company;
  final bool isSelected;
  final VoidCallback onTap;

  const ModernCompanyCardTile({
    super.key,
    required this.company,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final name = s.isArabic ? (company['name_ar'] ?? company['name_en'] ?? '') : (company['name_en'] ?? company['name_ar'] ?? '');
    final isGroup = company['is_group'] == true;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0284C7).withOpacity(0.12) : Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? const Color(0xFF0284C7) : Colors.transparent,
            width: 1.5,
          ),
          boxShadow: [
            if (!isSelected)
              BoxShadow(
                color: Colors.black.withOpacity(0.03),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isGroup ? Colors.amber.withOpacity(0.15) : const Color(0xFF0284C7).withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                isGroup ? Icons.account_tree_rounded : Icons.business_rounded,
                color: isGroup ? Colors.amber.shade800 : const Color(0xFF0284C7),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  if (isGroup)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        s.t('Holding Group', 'مجموعة قابضة'),
                        style: TextStyle(fontSize: 11, color: Colors.amber.shade800, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: isSelected ? const Color(0xFF0284C7) : Colors.grey.shade400),
          ],
        ),
      ),
    );
  }
}

// ----------------- شاشة تفاصيل البيانات المودرن (Dashboard Style) -----------------
class CompanyDetailsContent extends StatelessWidget {
  final Map<String, dynamic> company;
  final List<Map<String, dynamic>> allCompanies;
  final bool isLoggedIn;
  final bool canEdit;
  final Map<String, bool> privacy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onViewTaxCard;
  final VoidCallback onShare;

  const CompanyDetailsContent({
    super.key,
    required this.company,
    required this.allCompanies,
    required this.isLoggedIn,
    required this.canEdit,
    required this.privacy,
    required this.onEdit,
    required this.onDelete,
    required this.onViewTaxCard,
    required this.onShare,
  });

  void _openMaps(String? url) async {
    if (url == null || url.trim().isEmpty) return;
    final uri = Uri.parse(url.trim());
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final name = s.isArabic ? (company['name_ar'] ?? company['name_en'] ?? '') : (company['name_en'] ?? company['name_ar'] ?? '');

    final showMailing = isLoggedIn || (privacy['public_show_mailing_addresses'] ?? true);
    final showOps = isLoggedIn || (privacy['public_show_operation_addresses'] ?? false);

    final addresses = (company['company_addresses'] as List? ?? []).where((a) {
      if (a['type'] == 'mailing') return showMailing;
      if (a['type'] == 'operation') return showOps;
      return true;
    }).toList();

    final contacts = (company['company_contacts'] as List? ?? []);
    final isGroup = company['is_group'] == true;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10)],
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: isGroup ? Colors.amber.withOpacity(0.15) : const Color(0xFF0284C7).withOpacity(0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              isGroup ? s.t('Holding Group', 'مجموعة قابضة') : s.t('Standard Company', 'شركة مسجلة'),
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isGroup ? Colors.amber.shade800 : const Color(0xFF0284C7)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (company['tax_card_url'] != null)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      elevation: 0,
                    ),
                    icon: const Icon(Icons.badge_outlined, size: 18),
                    label: Text(s.t('View Tax Card', 'عرض البطاقة الضريبية')),
                    onPressed: onViewTaxCard,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Section Addresses
          if (addresses.isNotEmpty) ...[
            Text(s.t('Addresses & Locations', 'العناوين والخرائط'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 10),
            ...addresses.map((a) {
              final isMail = a['type'] == 'mailing';
              final addrText = s.isArabic ? (a['address_ar'] ?? a['address_en'] ?? '') : (a['address_en'] ?? a['address_ar'] ?? '');
              final mapUrl = isLoggedIn ? a['map_url']?.toString() : null;

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Icon(isMail ? Icons.location_city_rounded : Icons.factory_rounded, color: const Color(0xFF0284C7), size: 20),
                    const SizedBox(width: 12),
                    Expanded(child: Text(addrText, style: const TextStyle(fontSize: 14))),
                    if (isLoggedIn && mapUrl != null && mapUrl.trim().isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.map_rounded, color: Colors.redAccent, size: 20),
                        onPressed: () => _openMaps(mapUrl),
                      ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 20),
          ],

          // Section Contacts
          if (contacts.isNotEmpty) ...[
            Text(s.t('Contacts & Personnel', 'مسؤولو التواصل'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 10),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 320,
                mainAxisExtent: 110,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: contacts.length,
              itemBuilder: (ctx, idx) {
                final c = contacts[idx];
                final cName = s.isArabic ? (c['name_ar'] ?? c['name_en'] ?? '') : (c['name_en'] ?? c['name_ar'] ?? '');
                final cRole = isLoggedIn ? (s.isArabic ? (c['role_ar'] ?? c['role_en'] ?? '') : (c['role_en'] ?? c['role_ar'] ?? '')) : '****';
                final phone = isLoggedIn ? (c['phone'] ?? '') : '****';

                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(cName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      const SizedBox(height: 4),
                      Text(cRole, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                      const SizedBox(height: 4),
                      Text(phone, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF0284C7))),
                    ],
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

// ----------------- نافذة اللوج إن الزجاجية الأنيقة (Glassmorphism Dialog) -----------------
class GlassLoginDialog extends StatefulWidget {
  const GlassLoginDialog({super.key});

  @override
  State<GlassLoginDialog> createState() => _GlassLoginDialogState();
}

class _GlassLoginDialogState extends State<GlassLoginDialog> {
  final _pinController = TextEditingController();
  final _passController = TextEditingController();
  bool _stayLoggedIn = true;
  bool _loading = false;
  bool _obscurePass = true;
  String? _error;
  int _viewMode = 0; // 0: Login, 1: Request Access, 2: Reset Password

  final _nameReqController = TextEditingController();
  final _phoneReqController = TextEditingController();
  final _resetPinController = TextEditingController();
  final _resetPhoneController = TextEditingController();
  final _resetNewPassController = TextEditingController();

  void _login() async {
    final s = AppState.instance;
    final pin = _pinController.text.trim();
    final pass = _passController.text.trim();

    if (pin.isEmpty || pass.isEmpty) {
      setState(() => _error = s.t('Please enter PIN and Password', 'برجاء إدخال الكود وكلمة المرور'));
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final res = await Supabase.instance.client
          .from('app_users')
          .select()
          .eq('pin_code', pin)
          .eq('is_active', true)
          .maybeSingle();

      if (res == null) {
        setState(() => _error = s.t('Invalid PIN code or disabled', 'كود الدخول غير صحيح أو الحساب معطل'));
      } else {
        if (res['password_hash'] != pass) {
          setState(() => _error = s.t('Incorrect Password', 'كلمة المرور غير صحيحة'));
        } else {
          if (_stayLoggedIn) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('saved_user_session', jsonEncode(res));
          }
          if (mounted) Navigator.pop(context, res);
        }
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _submitAccountRequest() async {
    final name = _nameReqController.text.trim();
    final phone = _phoneReqController.text.trim();
    if (name.isEmpty || phone.isEmpty) return;

    await Supabase.instance.client.from('access_requests').insert({'full_name': name, 'phone': phone});

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppState.instance.t('Access request submitted', 'تم إرسال طلبك بنجاح!'))),
      );
    }
  }

  void _submitPasswordResetRequest() async {
    final pin = _resetPinController.text.trim();
    final phone = _resetPhoneController.text.trim();
    final newPass = _resetNewPassController.text.trim();
    if (pin.isEmpty || phone.isEmpty || newPass.isEmpty) return;

    setState(() => _loading = true);
    try {
      await Supabase.instance.client.from('password_resets').insert({'pin_code': pin, 'phone': phone, 'new_password': newPass});
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppState.instance.t('Reset request submitted', 'تم إرسال طلب التعيين للإدارة'))),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16),
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              width: 380,
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor.withOpacity(0.85),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: Colors.white.withOpacity(0.2), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 30,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Icon Header
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0284C7).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.login_rounded, color: Color(0xFF0284C7), size: 28),
                  ),
                  const SizedBox(height: 16),

                  Text(
                    _viewMode == 0
                        ? s.t('Sign in to CorpHub', 'تسجيل الدخول')
                        : _viewMode == 1
                            ? s.t('Request Access', 'طلب انضمام')
                            : s.t('Reset Password', 'استعادة كلمة المرور'),
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    s.t('Enter your details to proceed', 'أدخل بياناتك للمتابعة'),
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
                  const SizedBox(height: 24),

                  if (_viewMode == 0) ...[
                    TextField(
                      controller: _pinController,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      textAlign: TextAlign.center,
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: s.t('6-Digit PIN', 'كود الدخول (6 أرقام)'),
                        prefixIcon: const Icon(Icons.key_rounded, size: 20),
                        filled: true,
                        fillColor: Colors.grey.withOpacity(0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passController,
                      obscureText: _obscurePass,
                      textAlign: TextAlign.center,
                      decoration: InputDecoration(
                        hintText: s.t('Password', 'كلمة المرور'),
                        prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePass ? Icons.visibility_off : Icons.visibility, size: 18),
                          onPressed: () => setState(() => _obscurePass = !_obscurePass),
                        ),
                        filled: true,
                        fillColor: Colors.grey.withOpacity(0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(s.t('Stay logged in', 'تذكرني'), style: const TextStyle(fontSize: 12)),
                      value: _stayLoggedIn,
                      onChanged: (v) => setState(() => _stayLoggedIn = v ?? false),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                      ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0284C7),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          elevation: 0,
                        ),
                        onPressed: _loading ? null : _login,
                        child: _loading ? const CircularProgressIndicator(color: Colors.white) : Text(s.t('Log In', 'دخول'), style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        TextButton(
                          onPressed: () => setState(() => _viewMode = 1),
                          child: Text(s.t('Request Access', 'طلب حساب'), style: const TextStyle(fontSize: 12)),
                        ),
                        TextButton(
                          onPressed: () => setState(() => _viewMode = 2),
                          child: Text(s.t('Forgot Password?', 'نسيت المرور؟'), style: const TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ] else if (_viewMode == 1) ...[
                    TextField(
                      controller: _nameReqController,
                      decoration: InputDecoration(
                        hintText: s.t('Full Name', 'الاسم بالكامل'),
                        prefixIcon: const Icon(Icons.person_outline, size: 20),
                        filled: true,
                        fillColor: Colors.grey.withOpacity(0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _phoneReqController,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        hintText: s.t('WhatsApp Number', 'رقم الواتساب'),
                        prefixIcon: const Icon(Icons.phone_outlined, size: 20),
                        filled: true,
                        fillColor: Colors.grey.withOpacity(0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0284C7),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          elevation: 0,
                        ),
                        onPressed: _submitAccountRequest,
                        child: Text(s.t('Submit Request', 'إرسال الطلب'), style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => setState(() => _viewMode = 0),
                      child: Text(s.t('Back to log in', 'الرجوع لتسجيل الدخول')),
                    ),
                  ] else ...[
                    TextField(
                      controller: _resetPinController,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: s.t('6-Digit PIN', 'كود الدخول'),
                        prefixIcon: const Icon(Icons.key_rounded, size: 20),
                        filled: true,
                        fillColor: Colors.grey.withOpacity(0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _resetPhoneController,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        hintText: s.t('Phone Number', 'رقم الهاتف'),
                        prefixIcon: const Icon(Icons.phone_outlined, size: 20),
                        filled: true,
                        fillColor: Colors.grey.withOpacity(0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _resetNewPassController,
                      obscureText: true,
                      decoration: InputDecoration(
                        hintText: s.t('New Password', 'كلمة المرور الجديدة'),
                        prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
                        filled: true,
                        fillColor: Colors.grey.withOpacity(0.06),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber.shade800,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          elevation: 0,
                        ),
                        onPressed: _submitPasswordResetRequest,
                        child: Text(s.t('Submit Reset Request', 'إرسال طلب التعيين'), style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => setState(() => _viewMode = 0),
                      child: Text(s.t('Back to log in', 'الرجوع لتسجيل الدخول')),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ----------------- باقي العناصر الثانوية -----------------
class DesktopSidePanel extends StatelessWidget {
  final Map<String, dynamic> company;
  final List<Map<String, dynamic>> allCompanies;
  final bool isLoggedIn;
  final bool canEdit;
  final Map<String, bool> privacy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onViewTaxCard;
  final VoidCallback onShare;
  final VoidCallback onClose;

  const DesktopSidePanel({
    super.key,
    required this.company,
    required this.allCompanies,
    required this.isLoggedIn,
    required this.canEdit,
    required this.privacy,
    required this.onEdit,
    required this.onDelete,
    required this.onViewTaxCard,
    required this.onShare,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 8, right: 16),
            child: IconButton(icon: const Icon(Icons.close), onPressed: onClose),
          ),
        ),
        Expanded(
          child: CompanyDetailsContent(
            company: company,
            allCompanies: allCompanies,
            isLoggedIn: isLoggedIn,
            canEdit: canEdit,
            privacy: privacy,
            onEdit: onEdit,
            onDelete: onDelete,
            onViewTaxCard: onViewTaxCard,
            onShare: onShare,
          ),
        ),
      ],
    );
  }
}

class MobileCompanyDetailScreen extends StatelessWidget {
  final Map<String, dynamic> company;
  final List<Map<String, dynamic>> allCompanies;
  final bool isLoggedIn;
  final bool canEdit;
  final Map<String, bool> privacy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onViewTaxCard;
  final VoidCallback onShare;

  const MobileCompanyDetailScreen({
    super.key,
    required this.company,
    required this.allCompanies,
    required this.isLoggedIn,
    required this.canEdit,
    required this.privacy,
    required this.onEdit,
    required this.onDelete,
    required this.onViewTaxCard,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(company['name_ar'] ?? company['name_en'] ?? '')),
      body: CompanyDetailsContent(
        company: company,
        allCompanies: allCompanies,
        isLoggedIn: isLoggedIn,
        canEdit: canEdit,
        privacy: privacy,
        onEdit: onEdit,
        onDelete: onDelete,
        onViewTaxCard: onViewTaxCard,
        onShare: onShare,
      ),
    );
  }
}

class AdvancedCompanyDialog extends StatelessWidget {
  final Map<String, dynamic>? company;
  final List<Map<String, dynamic>> allCompanies;
  final bool isMobile;
  final VoidCallback? onDeleteRequested;

  const AdvancedCompanyDialog({super.key, this.company, required this.allCompanies, required this.isMobile, this.onDeleteRequested});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إضافة / تعديل شركة'),
      content: const Text('شاشة التعديل متاحة...'),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق'))],
    );
  }
}

class SelectivePrintDialog extends StatelessWidget {
  final Map<String, dynamic> company;
  const SelectivePrintDialog({super.key, required this.company});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('طباعة'),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق'))],
    );
  }
}

class AdminPanelScreen extends StatelessWidget {
  final Map<String, bool> privacy;
  final VoidCallback onUpdate;
  final List<Map<String, dynamic>> companies;
  final String? currentUserId;

  const AdminPanelScreen({super.key, required this.privacy, required this.onUpdate, required this.companies, this.currentUserId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('لوحة تحكم الإدارة')),
      body: const Center(child: Text('لوحة التحكم قيد التصميم...')),
    );
  }
}
