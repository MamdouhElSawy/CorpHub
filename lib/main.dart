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

  void _openChangePasswordDialog() {
    final s = AppState.instance;
    final oldPassCtrl = TextEditingController();
    final newPassCtrl = TextEditingController();
    final confirmPassCtrl = TextEditingController();
    String? err;
    bool saving = false;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Directionality(
        textDirection: s.isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: StatefulBuilder(
          builder: (ctx, setDialogState) => Dialog(
            backgroundColor: Colors.transparent,
            child: Container(
              width: 380,
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 30)],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(s.t('Change Password', 'تغيير كلمة المرور'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: oldPassCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      hintText: s.t('Current Password', 'كلمة المرور الحالية'),
                      filled: true,
                      fillColor: Colors.grey.withOpacity(0.06),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: newPassCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      hintText: s.t('New Password', 'كلمة المرور الجديدة'),
                      filled: true,
                      fillColor: Colors.grey.withOpacity(0.06),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: confirmPassCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      hintText: s.t('Confirm New Password', 'تأكيد كلمة المرور'),
                      filled: true,
                      fillColor: Colors.grey.withOpacity(0.06),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                    ),
                  ),
                  if (err != null) ...[
                    const SizedBox(height: 10),
                    Text(err!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0284C7),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: saving
                          ? null
                          : () async {
                              final oldP = oldPassCtrl.text.trim();
                              final newP = newPassCtrl.text.trim();
                              final confP = confirmPassCtrl.text.trim();

                              if (oldP != _currentUser!['password_hash']) {
                                setDialogState(() => err = s.t('Incorrect current password', 'كلمة المرور الحالية غير صحيحة'));
                                return;
                              }
                              if (newP.isEmpty) {
                                setDialogState(() => err = s.t('New password cannot be empty', 'كلمة المرور لا يمكن أن تكون فارغة'));
                                return;
                              }
                              if (newP != confP) {
                                setDialogState(() => err = s.t('Passwords do not match', 'كلمتا المرور غير متطابقتين'));
                                return;
                              }

                              setDialogState(() {
                                saving = true;
                                err = null;
                              });

                              try {
                                await Supabase.instance.client
                                    .from('app_users')
                                    .update({'password_hash': newP})
                                    .eq('id', _currentUser!['id']);

                                _currentUser!['password_hash'] = newP;
                                final prefs = await SharedPreferences.getInstance();
                                if (prefs.containsKey('saved_user_session')) {
                                  await prefs.setString('saved_user_session', jsonEncode(_currentUser));
                                }

                                if (mounted) {
                                  Navigator.pop(ctx);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(s.t('Password changed successfully!', 'تم تغيير كلمة المرور بنجاح!'))),
                                  );
                                }
                              } catch (e) {
                                setDialogState(() => err = e.toString());
                              } finally {
                                setDialogState(() => saving = false);
                              }
                            },
                      child: saving ? const CircularProgressIndicator(color: Colors.white) : Text(s.t('Update Password', 'تحديث كلمة المرور'), style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openLoginDialog() async {
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: true,
      builder: (_) => Directionality(
        textDirection: AppState.instance.isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: const CleanLoginDialog(),
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

  void _viewTaxCardImage(Map<String, dynamic> company) {
    final s = AppState.instance;
    final url = company['tax_card_url'];
    final companyName = s.isArabic ? (company['name_ar'] ?? company['name_en'] ?? '') : (company['name_en'] ?? company['name_ar'] ?? '');

    if (_currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.t('Please login to view tax card', 'برجاء تسجيل الدخول لعرض البطاقة الضريبية'))),
      );
      _openLoginDialog();
      return;
    }

    if (url == null || url.toString().isEmpty) {
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
                    Expanded(
                      child: Text(
                        '${s.t("Tax Card - ", "البطاقة الضريبية - ")} $companyName',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        overflow: TextOverflow.ellipsis,
                      ),
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
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF25D366), foregroundColor: Colors.white),
                      icon: const Icon(Icons.share, size: 16),
                      label: Text(s.t('Share Tax Card', 'مشاركة البطاقة')),
                      onPressed: () => _shareTaxCardAsWhatsApp(url, companyName),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7), foregroundColor: Colors.white),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: Text(s.t('Open Original', 'فتح الرابط الأصلي')),
                      onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _shareTaxCardAsWhatsApp(String? url, String companyName) async {
    final s = AppState.instance;
    if (_currentUser == null || url == null || url.trim().isEmpty) return;
    final msg = '${s.t("Tax Card Document for:", "مستند البطاقة الضريبية لشركة:")} $companyName\n\n$url';
    final wa = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(msg)}');
    if (await canLaunchUrl(wa)) {
      await launchUrl(wa, mode: LaunchMode.externalApplication);
    }
  }

  void _shareCompanyProfile(Map<String, dynamic> company) async {
    final s = AppState.instance;
    final name = s.isArabic ? (company['name_ar'] ?? company['name_en'] ?? '') : (company['name_en'] ?? company['name_ar'] ?? '');
    
    final addrs = (company['company_addresses'] as List? ?? []).map((a) {
      final addrText = s.isArabic ? (a['address_ar'] ?? a['address_en'] ?? '') : (a['address_en'] ?? a['address_ar'] ?? '');
      return '• [${a['type']}]: $addrText';
    }).join('\n');

    final contacts = (company['company_contacts'] as List? ?? []).map((c) {
      final cName = s.isArabic ? (c['name_ar'] ?? c['name_en'] ?? '') : (c['name_en'] ?? c['name_ar'] ?? '');
      final role = s.isArabic ? (c['role_ar'] ?? c['role_en'] ?? '') : (c['role_en'] ?? c['role_ar'] ?? '');
      return '👤 $cName ($role) - ${c['phone']}';
    }).join('\n');

    String summary = '${s.t("Company Profile:", "بروفايل الشركة:")} $name\n\n📍 ${s.t("Addresses", "العناوين")}:\n$addrs\n\n📞 ${s.t("Contacts", "المسؤولون")}:\n$contacts';
    if (company['tax_card_url'] != null) {
      summary += '\n\n📄 ${s.t("Tax Card", "البطاقة الضريبية")}: ${company['tax_card_url']}';
    }

    final wa = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(summary)}');
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
        titleSpacing: isDesktop ? 16 : 8,
        title: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF0284C7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('CorpHub', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.language, size: 20),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            constraints: const BoxConstraints(),
            onPressed: () {
              s.toggleLanguage();
              setState(() {});
            },
          ),
          IconButton(
            icon: Icon(s.themeMode == ThemeMode.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 20),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            constraints: const BoxConstraints(),
            onPressed: () => s.toggleTheme(),
          ),
          const SizedBox(width: 4),
          if (!isLoggedIn)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  elevation: 0,
                ),
                icon: const Icon(Icons.login, size: 14),
                label: Text(s.t('Login', 'دخول'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                onPressed: _openLoginDialog,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: PopupMenuButton<String>(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 11,
                        backgroundColor: const Color(0xFF0284C7),
                        child: Text((_currentUser!['username'] ?? 'U')[0].toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 4),
                      Text(_currentUser!['username'] ?? 'User', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      const Icon(Icons.arrow_drop_down, size: 16),
                    ],
                  ),
                ),
                onSelected: (val) async {
                  if (val == 'admin') {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => Directionality(
                          textDirection: s.isArabic ? TextDirection.rtl : TextDirection.ltr,
                          child: AdminPanelScreen(
                            privacy: _privacy,
                            onUpdate: _loadAll,
                            companies: _companies,
                            currentUserId: _currentUser?['id'],
                          ),
                        ),
                      ),
                    );
                  } else if (val == 'password') {
                    _openChangePasswordDialog();
                  } else if (val == 'logout') {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.remove('saved_user_session');
                    setState(() => _currentUser = null);
                  }
                },
                itemBuilder: (ctx) => [
                  if (_currentUser!['role'] == 'admin')
                    PopupMenuItem(
                      value: 'admin',
                      child: Row(
                        children: [
                          const Icon(Icons.admin_panel_settings, color: Color(0xFF0284C7), size: 18),
                          const SizedBox(width: 8),
                          Text(s.t('Admin Panel', 'لوحة تحكم الإدارة')),
                        ],
                      ),
                    ),
                  PopupMenuItem(
                    value: 'password',
                    child: Row(
                      children: [
                        const Icon(Icons.password, color: Colors.orangeAccent, size: 18),
                        const SizedBox(width: 8),
                        Text(s.t('Change Password', 'تغيير كلمة المرور')),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'logout',
                    child: Row(
                      children: [
                        const Icon(Icons.logout, color: Colors.redAccent, size: 18),
                        const SizedBox(width: 8),
                        Text(s.t('Logout', 'تسجيل الخروج')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(width: 4),
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
                SizedBox(
                  width: isDesktop ? _leftPaneWidth : MediaQuery.of(context).size.width,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
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
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
                                              onViewTaxCard: () => _viewTaxCardImage(comp),
                                              onShareProfile: () => _shareCompanyProfile(comp),
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
                            onViewTaxCard: () => _viewTaxCardImage(_selectedCompanyForPanel!),
                            onShareProfile: () => _shareCompanyProfile(_selectedCompanyForPanel!),
                            onClose: () => setState(() => _selectedCompanyForPanel = null),
                          ),
                  ),
                ],
              ],
            ),
    );
  }
}

class ModernCompanyCardTile extends StatelessWidget {
  final Map<String, dynamic> company;
  final bool isSelected;
  final VoidCallback onTap;

  const ModernCompanyCardTile({super.key, required this.company, required this.isSelected, required this.onTap});

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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0284C7).withOpacity(0.12) : Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: isSelected ? const Color(0xFF0284C7) : Colors.transparent, width: 1.5),
          boxShadow: [
            if (!isSelected) BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 8, offset: const Offset(0, 2)),
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
                    style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.w600, fontSize: 14),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (isGroup)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(s.t('Holding Group', 'مجموعة قابضة'), style: TextStyle(fontSize: 11, color: Colors.amber.shade800, fontWeight: FontWeight.bold)),
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

class CompanyDetailsContent extends StatelessWidget {
  final Map<String, dynamic> company;
  final List<Map<String, dynamic>> allCompanies;
  final bool isLoggedIn;
  final bool canEdit;
  final Map<String, bool> privacy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onViewTaxCard;
  final VoidCallback onShareProfile;

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
    required this.onShareProfile,
  });

  void _openMaps(String? url) async {
    if (url == null || url.trim().isEmpty) return;
    final uri = Uri.parse(url.trim());
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _shareLocationWhatsApp(String? url, String companyName) async {
    if (url == null || url.trim().isEmpty) return;
    final msg = '${AppProvider.t("Location for:", "موقع مقر شركة:")} $companyName\n📍 $url';
    final waUri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(msg)}');
    if (await canLaunchUrl(waUri)) {
      await launchUrl(waUri, mode: LaunchMode.externalApplication);
    }
  }

  void _shareContactWhatsApp(String cName, String cRole, String phone, String companyName) async {
    final msg = '${AppProvider.t("Contact Person for:", "مسؤول التواصل لشركة:")} $companyName\n👤 $cName\n💼 $cRole\n📞 $phone';
    final waUri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(msg)}');
    if (await canLaunchUrl(waUri)) {
      await launchUrl(waUri, mode: LaunchMode.externalApplication);
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
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10)],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
                        softWrap: true,
                      ),
                    ),
                    if (canEdit) ...[
                      IconButton(
                        icon: const Icon(Icons.edit, color: Color(0xFF0284C7), size: 20),
                        onPressed: onEdit,
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                        onPressed: onDelete,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
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
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (company['tax_card_url'] != null)
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0284C7),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          elevation: 0,
                        ),
                        icon: const Icon(Icons.badge_outlined, size: 16),
                        label: Text(s.t('View Tax Card', 'عرض البطاقة الضريبية'), style: const TextStyle(fontSize: 13)),
                        onPressed: onViewTaxCard,
                      ),
                    if (isLoggedIn)
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF25D366),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          elevation: 0,
                        ),
                        icon: const Icon(Icons.share, size: 16),
                        label: Text(s.t('Share Profile', 'مشاركة البروفايل'), style: const TextStyle(fontSize: 13)),
                        onPressed: onShareProfile,
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          if (addresses.isNotEmpty) ...[
            Text(s.t('Addresses & Locations', 'العناوين والخرائط'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 10),
            ...addresses.map((a) {
              final isMail = a['type'] == 'mailing';
              final addrText = s.isArabic ? (a['address_ar'] ?? a['address_en'] ?? '') : (a['address_en'] ?? a['address_ar'] ?? '');
              final mapUrl = isLoggedIn ? a['map_url']?.toString() : null;

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Icon(isMail ? Icons.location_city_rounded : Icons.factory_rounded, color: const Color(0xFF0284C7), size: 20),
                    const SizedBox(width: 10),
                    Expanded(child: Text(addrText, style: const TextStyle(fontSize: 13))),
                    if (isLoggedIn && mapUrl != null && mapUrl.trim().isNotEmpty) ...[
                      IconButton(
                        icon: const Icon(Icons.map_rounded, color: Colors.redAccent, size: 20),
                        tooltip: s.t('Open Map', 'فتح الخريطة'),
                        onPressed: () => _openMaps(mapUrl),
                      ),
                      IconButton(
                        icon: const Icon(Icons.share, color: Color(0xFF25D366), size: 20),
                        tooltip: s.t('Share Location', 'مشاركة اللوكيشن'),
                        onPressed: () => _shareLocationWhatsApp(mapUrl, name),
                      ),
                    ],
                  ],
                ),
              );
            }),
            const SizedBox(height: 20),
          ],

          if (contacts.isNotEmpty) ...[
            Text(s.t('Contacts & Personnel', 'مسؤولو التواصل'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                final isNarrow = constraints.maxWidth < 450;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: isNarrow ? 1 : 2,
                    mainAxisExtent: 115,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
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
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(cName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 2),
                                Text(cRole, style: TextStyle(fontSize: 12, color: Colors.grey.shade500), maxLines: 1, overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 4),
                                Text(phone, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF0284C7))),
                              ],
                            ),
                          ),
                          if (isLoggedIn) ...[
                            IconButton(
                              icon: const Icon(Icons.share, size: 18, color: Color(0xFF25D366)),
                              tooltip: s.t('Share Contact', 'مشاركة المسؤول'),
                              onPressed: () => _shareContactWhatsApp(cName, cRole, phone, name),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy, size: 18, color: Color(0xFF0284C7)),
                              tooltip: s.t('Copy', 'نسخ'),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: "Name: $cName\nRole: $cRole\nPhone: $phone"));
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('Copied!', 'تم النسخ!'))));
                              },
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

class DesktopSidePanel extends StatelessWidget {
  final Map<String, dynamic> company;
  final List<Map<String, dynamic>> allCompanies;
  final bool isLoggedIn;
  final bool canEdit;
  final Map<String, bool> privacy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onViewTaxCard;
  final VoidCallback onShareProfile;
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
    required this.onShareProfile,
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
            onShareProfile: onShareProfile,
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
  final VoidCallback onShareProfile;

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
    required this.onShareProfile,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final name = s.isArabic ? (company['name_ar'] ?? company['name_en'] ?? '') : (company['name_en'] ?? company['name_ar'] ?? '');

    return Scaffold(
      appBar: AppBar(
        title: Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      ),
      body: CompanyDetailsContent(
        company: company,
        allCompanies: allCompanies,
        isLoggedIn: isLoggedIn,
        canEdit: canEdit,
        privacy: privacy,
        onEdit: onEdit,
        onDelete: onDelete,
        onViewTaxCard: onViewTaxCard,
        onShareProfile: onShareProfile,
      ),
    );
  }
}

class AppProvider {
  static String t(String en, String ar) => AppState.instance.isArabic ? ar : en;
}

// ----------------- استمارة الإضافة والتعديل بتصميم موحد عائم ونظيف -----------------
class AdvancedCompanyDialog extends StatefulWidget {
  final Map<String, dynamic>? company;
  final List<Map<String, dynamic>> allCompanies;
  final bool isMobile;
  final VoidCallback? onDeleteRequested;

  const AdvancedCompanyDialog({
    super.key,
    this.company,
    required this.allCompanies,
    required this.isMobile,
    this.onDeleteRequested,
  });

  @override
  State<AdvancedCompanyDialog> createState() => _AdvancedCompanyDialogState();
}

class _AdvancedCompanyDialogState extends State<AdvancedCompanyDialog> {
  final _nameEn = TextEditingController();
  final _nameAr = TextEditingController();
  final _taxCardUrl = TextEditingController();

  bool _isGroup = false;
  bool _saving = false;
  bool _uploadingTaxCard = false;

  final List<Map<String, dynamic>> _addresses = [];
  final List<Map<String, dynamic>> _contacts = [];

  @override
  void initState() {
    super.initState();
    if (widget.company != null) {
      _nameEn.text = widget.company!['name_en'] ?? '';
      _nameAr.text = widget.company!['name_ar'] ?? '';
      _taxCardUrl.text = widget.company!['tax_card_url'] ?? '';
      _isGroup = widget.company!['is_group'] == true;

      final rawAddrs = widget.company!['company_addresses'] as List? ?? [];
      for (var a in rawAddrs) {
        _addresses.add({
          'type': a['type'] ?? 'mailing',
          'en': TextEditingController(text: a['address_en'] ?? ''),
          'ar': TextEditingController(text: a['address_ar'] ?? ''),
          'map_url': TextEditingController(text: a['map_url'] ?? ''),
        });
      }

      final rawContacts = widget.company!['company_contacts'] as List? ?? [];
      for (var c in rawContacts) {
        _contacts.add({
          'name_en': TextEditingController(text: c['name_en'] ?? ''),
          'name_ar': TextEditingController(text: c['name_ar'] ?? ''),
          'role': TextEditingController(text: c['role_en'] ?? c['role_ar'] ?? ''),
          'phone': TextEditingController(text: c['phone'] ?? ''),
        });
      }
    } else {
      _addresses.add({'type': 'mailing', 'en': TextEditingController(), 'ar': TextEditingController(), 'map_url': TextEditingController()});
      _contacts.add({'name_en': TextEditingController(), 'name_ar': TextEditingController(), 'role': TextEditingController(), 'phone': TextEditingController()});
    }
  }

  Future<void> _pickAndUploadTaxCard() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf'],
        withData: true,
      );

      if (res == null || res.files.single.bytes == null) return;

      setState(() => _uploadingTaxCard = true);
      Uint8List fileBytes = res.files.single.bytes!;
      final ext = res.files.single.extension?.toLowerCase() ?? 'png';
      final isPdf = ext == 'pdf';

      final fileName = 'tax_card_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final contentType = isPdf ? 'application/pdf' : 'image/png';

      await Supabase.instance.client.storage.from('tax-cards').uploadBinary(
            fileName,
            fileBytes,
            fileOptions: FileOptions(upsert: true, contentType: contentType),
          );

      final publicUrl = Supabase.instance.client.storage.from('tax-cards').getPublicUrl(fileName);
      setState(() => _taxCardUrl.text = publicUrl);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _uploadingTaxCard = false);
    }
  }

  void _saveAll() async {
    final en = _nameEn.text.trim();
    final ar = _nameAr.text.trim();
    if (en.isEmpty && ar.isEmpty) return;

    setState(() => _saving = true);
    try {
      final compData = {
        'name_en': en.isEmpty ? null : en,
        'name_ar': ar.isEmpty ? null : ar,
        'is_group': _isGroup,
        'tax_card_url': _taxCardUrl.text.trim().isEmpty ? null : _taxCardUrl.text.trim(),
      };

      String compId;
      if (widget.company == null) {
        final res = await Supabase.instance.client.from('companies').insert(compData).select().single();
        compId = res['id'];
      } else {
        compId = widget.company!['id'];
        await Supabase.instance.client.from('companies').update(compData).eq('id', compId);
        await Supabase.instance.client.from('company_addresses').delete().eq('company_id', compId);
        await Supabase.instance.client.from('company_contacts').delete().eq('company_id', compId);
      }

      for (var a in _addresses) {
        final aEn = (a['en'] as TextEditingController).text.trim();
        final aAr = (a['ar'] as TextEditingController).text.trim();
        final mapUrl = (a['map_url'] as TextEditingController).text.trim();
        if (aEn.isNotEmpty || aAr.isNotEmpty || mapUrl.isNotEmpty) {
          await Supabase.instance.client.from('company_addresses').insert({
            'company_id': compId,
            'type': a['type'],
            'address_en': aEn.isEmpty ? null : aEn,
            'address_ar': aAr.isEmpty ? null : aAr,
            'map_url': mapUrl.isEmpty ? null : mapUrl,
          });
        }
      }

      for (var c in _contacts) {
        final cEn = (c['name_en'] as TextEditingController).text.trim();
        final cAr = (c['name_ar'] as TextEditingController).text.trim();
        final role = (c['role'] as TextEditingController).text.trim();
        final phone = (c['phone'] as TextEditingController).text.trim();
        if (cEn.isNotEmpty || cAr.isNotEmpty || phone.isNotEmpty) {
          await Supabase.instance.client.from('company_contacts').insert({
            'company_id': compId,
            'name_en': cEn.isEmpty ? null : cEn,
            'name_ar': cAr.isEmpty ? null : cAr,
            'role_en': role.isEmpty ? null : role,
            'role_ar': role.isEmpty ? null : role,
            'phone': phone.isEmpty ? null : phone,
          });
        }
      }

      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _cleanDecoration(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      prefixIcon: Icon(icon, size: 20),
      filled: true,
      fillColor: Colors.grey.withOpacity(0.06),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Center(
        child: Container(
          width: 480,
          constraints: const BoxConstraints(maxHeight: 680),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(28),
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0284C7).withOpacity(0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(widget.company == null ? Icons.add_business_rounded : Icons.edit_note_rounded, color: const Color(0xFF0284C7), size: 22),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        widget.company == null ? s.t('Add New Company', 'إضافة شركة جديدة') : s.t('Edit Company', 'تعديل بيانات الشركة'),
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  children: [
                    TextField(
                      controller: _nameAr,
                      decoration: _cleanDecoration(s.t('Company Name (Arabic)', 'اسم الشركة بالعربية'), Icons.business_rounded),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _nameEn,
                      decoration: _cleanDecoration(s.t('Company Name (English)', 'اسم الشركة بالإنجليزي'), Icons.language_rounded),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(s.t('Holding Group?', 'مجموعة قابضة؟'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      value: _isGroup,
                      onChanged: (v) => setState(() => _isGroup = v),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _taxCardUrl,
                            decoration: _cleanDecoration(s.t('Tax Card File URL', 'رابط البطاقة الضريبية'), Icons.badge_outlined),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 48,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0284C7),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              elevation: 0,
                            ),
                            icon: _uploadingTaxCard ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.upload_file_rounded, size: 18),
                            label: Text(s.t('Upload', 'رفع')),
                            onPressed: _uploadingTaxCard ? null : _pickAndUploadTaxCard,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(s.t('Addresses:', 'العناوين والخرائط:'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 8),
                    ..._addresses.map((a) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          children: [
                            TextField(controller: a['ar'], decoration: _cleanDecoration(s.t('Address (Arabic)', 'العنوان بالعربي'), Icons.location_on_outlined)),
                            const SizedBox(height: 6),
                            TextField(controller: a['map_url'], decoration: _cleanDecoration(s.t('Map Link', 'رابط الخريطة'), Icons.map_outlined)),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 12),
                    Text(s.t('Contacts:', 'مسؤولو التواصل:'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 8),
                    ..._contacts.map((c) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          children: [
                            TextField(controller: c['name_ar'], decoration: _cleanDecoration(s.t('Full Name', 'الاسم بالكامل'), Icons.person_outline_rounded)),
                            const SizedBox(height: 6),
                            TextField(controller: c['role'], decoration: _cleanDecoration(s.t('Job Title', 'المسمى الوظيفي'), Icons.work_outline_rounded)),
                            const SizedBox(height: 6),
                            TextField(controller: c['phone'], decoration: _cleanDecoration(s.t('Phone Number', 'رقم الهاتف'), Icons.phone_outlined)),
                          ],
                        ),
                      );
                    }),
                  ],
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
                  onPressed: _saving ? null : _saveAll,
                  child: _saving ? const CircularProgressIndicator(color: Colors.white) : Text(s.t('Save Changes', 'حفظ البيانات'), style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CleanLoginDialog extends StatefulWidget {
  const CleanLoginDialog({super.key});

  @override
  State<CleanLoginDialog> createState() => _CleanLoginDialogState();
}

class _CleanLoginDialogState extends State<CleanLoginDialog> {
  final _pinController = TextEditingController();
  final _passController = TextEditingController();
  bool _stayLoggedIn = true;
  bool _loading = false;
  bool _obscurePass = true;
  String? _error;
  int _viewMode = 0;

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
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(28),
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
    );
  }
}

// ----------------- لوحة تحكم الإدارة بتصميم السايدبار المريح الهادئ -----------------
class AdminPanelScreen extends StatefulWidget {
  final Map<String, bool> privacy;
  final VoidCallback onUpdate;
  final List<Map<String, dynamic>> companies;
  final String? currentUserId;

  const AdminPanelScreen({super.key, required this.privacy, required this.onUpdate, required this.companies, this.currentUserId});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  int _selectedTabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    final navItems = [
      {'icon': Icons.security_rounded, 'title': s.t('Privacy Settings', 'إعدادات الخصوصية')},
      {'icon': Icons.people_alt_rounded, 'title': s.t('User Management', 'إدارة المستخدمين')},
      {'icon': Icons.mark_email_unread_rounded, 'title': s.t('Access Requests', 'طلبات الحسابات')},
      {'icon': Icons.backup_rounded, 'title': s.t('Backup & Data', 'النسخ الاحتياطي')},
    ];

    Widget currentBody;
    switch (_selectedTabIndex) {
      case 0:
        currentBody = _PrivacySettingsTab(privacy: widget.privacy, onUpdate: widget.onUpdate);
        break;
      case 1:
        currentBody = _UserManagementTab(currentUserId: widget.currentUserId);
        break;
      case 2:
        currentBody = const _AccessRequestsTab();
        break;
      case 3:
        currentBody = _BackupTab(companies: widget.companies, onRestore: widget.onUpdate);
        break;
      default:
        currentBody = const SizedBox.shrink();
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('Admin Control Panel', 'لوحة تحكم الإدارة'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        elevation: 0,
        backgroundColor: Theme.of(context).colorScheme.surface,
      ),
      body: isDesktop
          ? Row(
              children: [
                Container(
                  width: 240,
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    border: Border(left: BorderSide(color: Colors.grey.withOpacity(0.12))),
                  ),
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                    itemCount: navItems.length,
                    itemBuilder: (ctx, idx) {
                      final item = navItems[idx];
                      final isSel = _selectedTabIndex == idx;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          tileColor: isSel ? const Color(0xFF0284C7).withOpacity(0.12) : Colors.transparent,
                          leading: Icon(item['icon'] as IconData, color: isSel ? const Color(0xFF0284C7) : Colors.grey.shade500, size: 20),
                          title: Text(
                            item['title'] as String,
                            style: TextStyle(fontWeight: isSel ? FontWeight.bold : FontWeight.normal, color: isSel ? const Color(0xFF0284C7) : null, fontSize: 13),
                          ),
                          onTap: () => setState(() => _selectedTabIndex = idx),
                        ),
                      );
                    },
                  ),
                ),
                Expanded(child: Padding(padding: const EdgeInsets.all(24), child: currentBody)),
              ],
            )
          : Column(
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: List.generate(navItems.length, (idx) {
                      final item = navItems[idx];
                      final isSel = _selectedTabIndex == idx;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ChoiceChip(
                          label: Text(item['title'] as String),
                          selected: isSel,
                          onSelected: (_) => setState(() => _selectedTabIndex = idx),
                          selectedColor: const Color(0xFF0284C7),
                          labelStyle: TextStyle(color: isSel ? Colors.white : null, fontWeight: isSel ? FontWeight.bold : FontWeight.normal),
                        ),
                      );
                    }),
                  ),
                ),
                Expanded(child: Padding(padding: const EdgeInsets.all(16), child: currentBody)),
              ],
            ),
    );
  }
}

class _PrivacySettingsTab extends StatefulWidget {
  final Map<String, bool> privacy;
  final VoidCallback onUpdate;

  const _PrivacySettingsTab({required this.privacy, required this.onUpdate});

  @override
  State<_PrivacySettingsTab> createState() => _PrivacySettingsTabState();
}

class _PrivacySettingsTabState extends State<_PrivacySettingsTab> {
  bool _saving = false;

  void _saveKey(String key, bool val) async {
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.from('system_settings').upsert({'key': key, 'value': val.toString()});
      widget.privacy[key] = val;
      widget.onUpdate();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.t('Guest Visibility Settings', 'إعدادات خصوصية الزوار والضيوف'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 16),
          SwitchListTile(
            title: Text(s.t('Allow Public Browsing', 'السماح بالاستعراض العام بدون تسجيل')),
            value: widget.privacy['allow_public_read'] ?? true,
            onChanged: (v) => _saveKey('allow_public_read', v),
          ),
          SwitchListTile(
            title: Text(s.t('Show Tax Card to Public', 'إظهار البطاقة الضريبية للعامة')),
            value: widget.privacy['public_show_tax_card'] ?? false,
            onChanged: (v) => _saveKey('public_show_tax_card', v),
          ),
          SwitchListTile(
            title: Text(s.t('Show Phone Numbers to Public', 'إظهار أرقام الهواتف للعامة')),
            value: widget.privacy['public_show_phones'] ?? false,
            onChanged: (v) => _saveKey('public_show_phones', v),
          ),
          SwitchListTile(
            title: Text(s.t('Show Operation Addresses to Public', 'إظهار عناوين المقرات والتطبيق للعامة')),
            value: widget.privacy['public_show_operation_addresses'] ?? false,
            onChanged: (v) => _saveKey('public_show_operation_addresses', v),
          ),
        ],
      ),
    );
  }
}

class _UserManagementTab extends StatefulWidget {
  final String? currentUserId;
  const _UserManagementTab({this.currentUserId});

  @override
  State<_UserManagementTab> createState() => _UserManagementTabState();
}

class _UserManagementTabState extends State<_UserManagementTab> {
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchUsers();
  }

  Future<void> _fetchUsers() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.from('app_users').select().order('created_at');
      if (mounted) setState(() => _users = List<Map<String, dynamic>>.from(res));
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(s.t('System Users', 'قائمة مستخدمي النظام'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchUsers),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.separated(
                    itemCount: _users.length,
                    separatorBuilder: (_, __) => const Divider(),
                    itemBuilder: (ctx, idx) {
                      final u = _users[idx];
                      return ListTile(
                        leading: CircleAvatar(child: Text((u['username'] ?? 'U')[0].toUpperCase())),
                        title: Text(u['username'] ?? 'User'),
                        subtitle: Text('PIN: ${u['pin_code']} | Role: ${u['role']}'),
                        trailing: Switch(
                          value: u['is_active'] == true,
                          onChanged: (v) async {
                            await Supabase.instance.client.from('app_users').update({'is_active': v}).eq('id', u['id']);
                            _fetchUsers();
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _AccessRequestsTab extends StatefulWidget {
  const _AccessRequestsTab();

  @override
  State<_AccessRequestsTab> createState() => _AccessRequestsTabState();
}

class _AccessRequestsTabState extends State<_AccessRequestsTab> {
  List<Map<String, dynamic>> _reqs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchRequests();
  }

  Future<void> _fetchRequests() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.from('access_requests').select().order('created_at');
      if (mounted) setState(() => _reqs = List<Map<String, dynamic>>.from(res));
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.t('New Account Requests', 'طلبات إنشاء الحسابات الجديدة'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _reqs.isEmpty
                    ? Center(child: Text(s.t('No pending requests', 'لا توجد طلبات معلقة')))
                    : ListView.separated(
                        itemCount: _reqs.length,
                        separatorBuilder: (_, __) => const Divider(),
                        itemBuilder: (ctx, idx) {
                          final r = _reqs[idx];
                          return ListTile(
                            title: Text(r['full_name'] ?? ''),
                            subtitle: Text(r['phone'] ?? ''),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, color: Colors.redAccent),
                              onPressed: () async {
                                await Supabase.instance.client.from('access_requests').delete().eq('id', r['id']);
                                _fetchRequests();
                              },
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _BackupTab extends StatelessWidget {
  final List<Map<String, dynamic>> companies;
  final VoidCallback onRestore;

  const _BackupTab({required this.companies, required this.onRestore});

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.t('Backup & Data Management', 'إدارة البيانات والنسخ الاحتياطي'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7), foregroundColor: Colors.white),
            icon: const Icon(Icons.download),
            label: Text(s.t('Export Companies to JSON', 'تصدير كافة الشركات كملف JSON')),
            onPressed: () {
              final str = jsonEncode(companies);
              final bytes = utf8.encode(str);
              final blob = html.Blob([bytes]);
              final url = html.Url.createObjectUrlFromBlob(blob);
              html.AnchorElement(href: url)
                ..setAttribute("download", "corphub_backup_${DateTime.now().millisecondsSinceEpoch}.json")
                ..click();
              html.Url.revokeObjectUrl(url);
            },
          ),
        ],
      ),
    );
  }
}
