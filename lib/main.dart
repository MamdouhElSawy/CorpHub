import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart';
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

// ----------------- إدارة اللغات والمظهر وهيكل EGL -----------------
class AppState extends ChangeNotifier {
  static final AppState instance = AppState._();
  AppState._();

  bool isArabic = false;
  ThemeMode themeMode = ThemeMode.dark;

  Future<void> loadSavedPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey('app_is_arabic')) {
        isArabic = prefs.getBool('app_is_arabic') ?? false;
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

  void toggleTheme(bool dark) async {
    themeMode = dark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('app_is_dark', dark);
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
        const eglNavyDark = Color(0xFF0B192C);
        const eglNavyCard = Color(0xFF1E3E62);
        const eglBlueAccent = Color(0xFF008DDA);

        return MaterialApp(
          title: state.isArabic ? 'دليل الشركات' : 'CorpHub - EGL',
          debugShowCheckedModeBanner: false,
          themeMode: state.themeMode,
          locale: Locale(state.isArabic ? 'ar' : 'en'),
          theme: ThemeData(
            brightness: Brightness.light,
            scaffoldBackgroundColor: const Color(0xFFF4F6F9),
            primaryColor: const Color(0xFF0B2545),
            cardColor: Colors.white,
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF0B2545),
              secondary: Color(0xFF0077B6),
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
              secondary: Color(0xFF41B06E),
              surface: eglNavyCard,
            ),
          ),
          home: const MainHomeScreen(),
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

  Future<void> _fetchCompanies() async {
    try {
      final res = await Supabase.instance.client
          .from('companies')
          .select('*, company_addresses(*), company_contacts(*)')
          .order('created_at', ascending: false);
      _companies = List<Map<String, dynamic>>.from(res);
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
      builder: (ctx) => AlertDialog(
        title: Text(s.t('Delete Company', 'حذف الشركة')),
        content: Text(
          s.t(
            'Are you sure you want to delete "$name" and all its associated addresses and contacts?',
            'هل أنت متأكد من حذف شركة "$name" وجميع عناوينها وجهات الاتصال الخاصة بها؟',
          ),
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
    );

    if (confirm == true) {
      setState(() => _loading = true);
      try {
        final compId = company['id'];
        await Supabase.instance.client.from('company_contacts').delete().eq('company_id', compId);
        await Supabase.instance.client.from('company_addresses').delete().eq('company_id', compId);
        await Supabase.instance.client.from('companies').delete().eq('id', compId);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s.t('Company deleted successfully', 'تم حذف الشركة بنجاح'))),
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
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(s.t('Change Password', 'تغيير كلمة المرور')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: oldPassCtrl,
                obscureText: true,
                decoration: InputDecoration(labelText: s.t('Current Password', 'كلمة المرور الحالية')),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: newPassCtrl,
                obscureText: true,
                decoration: InputDecoration(labelText: s.t('New Password', 'كلمة المرور الجديدة')),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: confirmPassCtrl,
                obscureText: true,
                decoration: InputDecoration(labelText: s.t('Confirm New Password', 'تأكيد كلمة المرور الجديدة')),
              ),
              if (err != null) ...[
                const SizedBox(height: 10),
                Text(err!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(s.t('Cancel', 'إلغاء')),
            ),
            ElevatedButton(
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
              child: saving ? const CircularProgressIndicator() : Text(s.t('Update Password', 'تحديث كلمة المرور')),
            ),
          ],
        ),
      ),
    );
  }

  void _openSettingsMenu() {
    final s = AppState.instance;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.language),
                title: Text(s.t('Language: English', 'اللغة: العربية')),
                subtitle: Text(s.isArabic ? 'اضغط للتحويل إلى الإنجليزية' : 'Switch to Arabic'),
                trailing: Switch(
                  value: s.isArabic,
                  onChanged: (val) {
                    s.toggleLanguage();
                    setModalState(() {});
                    setState(() {});
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.dark_mode_outlined),
                title: Text(s.t('Dark Theme', 'الوضع الليلي')),
                trailing: Switch(
                  value: s.themeMode == ThemeMode.dark,
                  onChanged: (val) {
                    s.toggleTheme(val);
                    setModalState(() {});
                  },
                ),
              ),
              const Divider(),
              if (_currentUser == null)
                ListTile(
                  leading: const Icon(Icons.login),
                  title: Text(s.t('Login', 'تسجيل الدخول')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _openLoginDialog();
                  },
                )
              else ...[
                if (_currentUser!['role'] == 'admin')
                  ListTile(
                    leading: const Icon(Icons.admin_panel_settings, color: Color(0xFF008DDA)),
                    title: Text(s.t('Admin Control Panel', 'لوحة تحكم الإدارة')),
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AdminPanelScreen(
                            privacy: _privacy,
                            onUpdate: _loadAll,
                            companies: _companies,
                          ),
                        ),
                      );
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.password, color: Colors.orangeAccent),
                  title: Text(s.t('Change Password', 'تغيير كلمة المرور')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _openChangePasswordDialog();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.logout, color: Colors.redAccent),
                  title: Text('${s.t("Logout", "خروج")} (${_currentUser!["username"] ?? ""}) - ${_currentUser!["role"]?.toString().toUpperCase()}'),
                  onTap: () async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.remove('saved_user_session');
                    setState(() => _currentUser = null);
                    Navigator.pop(ctx);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _openLoginDialog() async {
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const CleanLoginDialog(),
    );
    if (res != null) {
      setState(() => _currentUser = res);
    }
  }

  void _openAddEditCompanyDialog([Map<String, dynamic>? company]) async {
    final res = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AdvancedCompanyDialog(
        company: company,
        allCompanies: _companies,
        onDeleteRequested: company != null ? () => _deleteSingleCompany(company) : null,
      ),
    );
    if (res == true) _loadAll();
  }

  void _shareOnWhatsApp(String? url, String companyName) async {
    final s = AppState.instance;
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.t('No tax card uploaded', 'لا توجد صورة مسجلة'))),
      );
      return;
    }
    final msg = '${s.t("Tax Card for:", "البطاقة الضريبية لشركة:")} $companyName\n$url';
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

    final filtered = _companies.where((c) {
      final nameAr = (c['name_ar'] ?? '').toString().toLowerCase();
      final nameEn = (c['name_en'] ?? '').toString().toLowerCase();
      final q = _searchQuery.toLowerCase();
      return nameAr.contains(q) || nameEn.contains(q);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        elevation: 1,
        title: Row(
          children: [
            Image.network(
              'https://www.eglegypt.com/wp-content/uploads/2021/04/EGL-Logo-white.png',
              height: 34,
              errorBuilder: (_, __, ___) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: const Color(0xFF008DDA), borderRadius: BorderRadius.circular(6)),
                child: const Text('EGL', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white)),
              ),
            ),
            const SizedBox(width: 12),
            Text(s.t('CorpHub Directory', 'دليل الشركات'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: s.t('Settings', 'الإعدادات'),
            onPressed: _openSettingsMenu,
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: _canEdit
          ? FloatingActionButton.extended(
              backgroundColor: const Color(0xFF008DDA),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_business),
              label: Text(s.t('Add Company', 'إضافة شركة')),
              onPressed: () => _openAddEditCompanyDialog(),
            )
          : null,
      body: !canBrowse
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.lock_outline, size: 64, color: Color(0xFF008DDA)),
                  const SizedBox(height: 16),
                  Text(s.t('Browsing restricted to members', 'التصفح مغلق لغير المسجلين'), style: const TextStyle(fontSize: 18)),
                  const SizedBox(height: 12),
                  ElevatedButton(onPressed: _openLoginDialog, child: Text(s.t('Login', 'تسجيل الدخول'))),
                ],
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: s.t('Search company name...', 'ابحث باسم الشركة...'),
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onChanged: (val) => setState(() => _searchQuery = val),
                  ),
                ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : filtered.isEmpty
                          ? Center(child: Text(s.t('No companies found', 'لا توجد بيانات مسجلة')))
                          : ListView.separated(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 12),
                              itemBuilder: (ctx, i) {
                                final comp = filtered[i];
                                return CompanyCard(
                                  company: comp,
                                  allCompanies: _companies,
                                  isLoggedIn: isLoggedIn,
                                  canEdit: _canEdit,
                                  privacy: _privacy,
                                  onEdit: () => _openAddEditCompanyDialog(comp),
                                  onDelete: () => _deleteSingleCompany(comp),
                                  onShare: () => _shareOnWhatsApp(
                                    comp['tax_card_url'],
                                    s.isArabic ? (comp['name_ar'] ?? comp['name_en'] ?? '') : (comp['name_en'] ?? comp['name_ar'] ?? ''),
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

// ----------------- كارت عرض الشركة -----------------
class CompanyCard extends StatelessWidget {
  final Map<String, dynamic> company;
  final List<Map<String, dynamic>> allCompanies;
  final bool isLoggedIn;
  final bool canEdit;
  final Map<String, bool> privacy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onShare;

  const CompanyCard({
    super.key,
    required this.company,
    required this.allCompanies,
    required this.isLoggedIn,
    required this.canEdit,
    required this.privacy,
    required this.onEdit,
    required this.onDelete,
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

    final showTax = isLoggedIn || (privacy['public_show_tax_card'] ?? false);
    final showPhones = isLoggedIn || (privacy['public_show_phones'] ?? false);
    final showMailing = isLoggedIn || (privacy['public_show_mailing_addresses'] ?? true);
    final showOps = isLoggedIn || (privacy['public_show_operation_addresses'] ?? false);
    final showRelations = isLoggedIn || (privacy['public_show_relations'] ?? true);

    final addresses = (company['company_addresses'] as List? ?? []).where((a) {
      if (a['type'] == 'mailing') return showMailing;
      if (a['type'] == 'operation') return showOps;
      return true;
    }).toList();

    final contacts = (company['company_contacts'] as List? ?? []);
    final isGroup = company['is_group'] == true;
    final parentId = company['parent_company_id'];
    final mapsUrl = company['google_maps_url']?.toString();

    String? parentName;
    if (parentId != null) {
      final parent = allCompanies.firstWhere((c) => c['id'] == parentId, orElse: () => {});
      if (parent.isNotEmpty) {
        parentName = s.isArabic ? (parent['name_ar'] ?? parent['name_en']) : (parent['name_en'] ?? parent['name_ar']);
      }
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: isGroup ? Colors.amber.withOpacity(0.2) : Theme.of(context).primaryColor.withOpacity(0.15),
          child: Icon(
            isGroup ? Icons.account_tree : Icons.corporate_fare,
            color: isGroup ? Colors.amber.shade800 : Theme.of(context).primaryColor,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(child: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
                      if (isGroup) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: Colors.amber.shade800, borderRadius: BorderRadius.circular(4)),
                          child: Text(s.t('Group / Holding', 'مجموعة قابضة'), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ],
                  ),
                  if (showRelations && parentName != null)
                    Text(
                      '${s.t("Subsidiary of:", "تابعة لمجموعة:")} $parentName',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontStyle: FontStyle.italic),
                    ),
                ],
              ),
            ),
            if (canEdit) ...[
              IconButton(
                icon: const Icon(Icons.edit, size: 20, color: Color(0xFF008DDA)),
                tooltip: s.t('Edit Company', 'تعديل بيانات الشركة'),
                onPressed: onEdit,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                tooltip: s.t('Delete Company', 'حذف الشركة نهائياً'),
                onPressed: onDelete,
              ),
            ],
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (showTax && company['tax_card_url'] != null)
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF25D366), foregroundColor: Colors.white),
                        icon: const Icon(Icons.share, size: 16),
                        label: Text(s.t('WhatsApp Card', 'واتساب البطاقة')),
                        onPressed: onShare,
                      ),
                    if (mapsUrl != null && mapsUrl.isNotEmpty)
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                        icon: const Icon(Icons.location_on, size: 16),
                        label: Text(s.t('Google Maps', 'الموقع على الخريطة')),
                        onPressed: () => _openMaps(mapsUrl),
                      ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.print, size: 16),
                      label: Text(s.t('Selective Print', 'طباعة مخصصة')),
                      onPressed: () => showDialog(
                        context: context,
                        builder: (_) => SelectivePrintDialog(company: company),
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                if (addresses.isNotEmpty) ...[
                  Text(s.t('📍 Addresses:', '📍 العناوين:'), style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).primaryColor)),
                  const SizedBox(height: 6),
                  ...addresses.map((a) {
                    final isMail = a['type'] == 'mailing';
                    final addrText = s.isArabic ? (a['address_ar'] ?? a['address_en'] ?? '') : (a['address_en'] ?? a['address_ar'] ?? '');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text('• [${isMail ? s.t("Mailing", "مراسلة") : s.t("Operation", "تشغيل")}]: $addrText'),
                    );
                  }),
                  const SizedBox(height: 12),
                ],
                if (contacts.isNotEmpty) ...[
                  Text(s.t('👤 Contacts:', '👤 جهات الاتصال:'), style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).primaryColor)),
                  const SizedBox(height: 6),
                  ...contacts.map((c) {
                    final cName = s.isArabic ? (c['name_ar'] ?? c['name_en'] ?? '') : (c['name_en'] ?? c['name_ar'] ?? '');
                    final cRole = s.isArabic ? (c['role_ar'] ?? c['role_en'] ?? '') : (c['role_en'] ?? c['role_ar'] ?? '');
                    final phone = showPhones ? (c['phone'] ?? '') : '••••••••••';

                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('$cName ($cRole)'),
                      subtitle: SelectableText(phone),
                      trailing: showPhones
                          ? IconButton(
                              icon: const Icon(Icons.copy, size: 18),
                              tooltip: s.t('Copy Contact', 'نسخ جهة الاتصال'),
                              onPressed: () {
                                final formattedContact = "Name : $cName\nNumber: $phone";
                                Clipboard.setData(ClipboardData(text: formattedContact));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(s.t('Contact copied to clipboard!', 'تم نسخ جهة الاتصال إلى الحافظة!'))),
                                );
                              },
                            )
                          : null,
                    );
                  }),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ----------------- استمارة إضافة وتعديل الشركة -----------------
class AdvancedCompanyDialog extends StatefulWidget {
  final Map<String, dynamic>? company;
  final List<Map<String, dynamic>> allCompanies;
  final VoidCallback? onDeleteRequested;

  const AdvancedCompanyDialog({
    super.key,
    this.company,
    required this.allCompanies,
    this.onDeleteRequested,
  });

  @override
  State<AdvancedCompanyDialog> createState() => _AdvancedCompanyDialogState();
}

class _AdvancedCompanyDialogState extends State<AdvancedCompanyDialog> {
  final _nameEn = TextEditingController();
  final _nameAr = TextEditingController();
  final _taxCardUrl = TextEditingController();
  final _mapsUrl = TextEditingController();
  bool _isGroup = false;
  String? _parentCompanyId;

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
      _mapsUrl.text = widget.company!['google_maps_url'] ?? '';
      _isGroup = widget.company!['is_group'] == true;
      _parentCompanyId = widget.company!['parent_company_id'];

      final rawAddrs = widget.company!['company_addresses'] as List? ?? [];
      for (var a in rawAddrs) {
        _addresses.add({
          'type': a['type'] ?? 'mailing',
          'en': TextEditingController(text: a['address_en'] ?? ''),
          'ar': TextEditingController(text: a['address_ar'] ?? ''),
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
      _addresses.add({'type': 'mailing', 'en': TextEditingController(), 'ar': TextEditingController()});
      _contacts.add({'name_en': TextEditingController(), 'name_ar': TextEditingController(), 'role': TextEditingController(), 'phone': TextEditingController()});
    }
  }

  Future<void> _pickAndUploadTaxCard() async {
    final s = AppState.instance;
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf'],
        withData: true,
      );

      if (res == null || res.files.single.bytes == null) return;

      setState(() => _uploadingTaxCard = true);
      final fileBytes = res.files.single.bytes!;
      final ext = res.files.single.extension ?? 'png';
      final fileName = 'tax_card_${DateTime.now().millisecondsSinceEpoch}.$ext';

      await Supabase.instance.client.storage.from('tax_cards').uploadBinary(
            fileName,
            fileBytes,
            fileOptions: FileOptions(upsert: true, contentType: 'image/$ext'),
          );

      final publicUrl = Supabase.instance.client.storage.from('tax_cards').getPublicUrl(fileName);
      setState(() {
        _taxCardUrl.text = publicUrl;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.t('Tax card uploaded successfully!', 'تم رفع صورة البطاقة الضريبية بنجاح!'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _uploadingTaxCard = false);
    }
  }

  void _saveAll() async {
    final s = AppState.instance;
    final en = _nameEn.text.trim();
    final ar = _nameAr.text.trim();

    if (en.isEmpty && ar.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('Please enter company name', 'برجاء كتابة اسم الشركة'))));
      return;
    }

    setState(() => _saving = true);

    try {
      final compData = {
        'name_en': en.isEmpty ? null : en,
        'name_ar': ar.isEmpty ? null : ar,
        'tax_card_url': _taxCardUrl.text.trim().isEmpty ? null : _taxCardUrl.text.trim(),
        'google_maps_url': _mapsUrl.text.trim().isEmpty ? null : _mapsUrl.text.trim(),
        'is_group': _isGroup,
        'parent_company_id': _isGroup ? null : _parentCompanyId,
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
        if (aEn.isNotEmpty || aAr.isNotEmpty) {
          await Supabase.instance.client.from('company_addresses').insert({
            'company_id': compId,
            'type': a['type'],
            'address_en': aEn.isEmpty ? null : aEn,
            'address_ar': aAr.isEmpty ? null : aAr,
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
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Database Error: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final potentialParents = widget.allCompanies.where((c) => c['id'] != widget.company?['id']).toList();

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 650,
        height: 750,
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Row(
              children: [
                Icon(widget.company == null ? Icons.add_business : Icons.edit, color: const Color(0xFF008DDA)),
                const SizedBox(width: 8),
                Text(
                  widget.company == null ? s.t('Register New Company', 'تسجيل شركة جديدة') : s.t('Edit Company Details', 'تعديل بيانات الشركة'),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView(
                children: [
                  Text(s.t('1. Company Information', '١. بيانات الشركة الأساسية'), style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF008DDA))),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _nameEn,
                          decoration: InputDecoration(labelText: s.t('Name (English)', 'الاسم بالإنجليزية'), prefixIcon: const Icon(Icons.language)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _nameAr,
                          decoration: InputDecoration(labelText: s.t('Name (Arabic)', 'الاسم بالعربية'), prefixIcon: const Icon(Icons.translate)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _mapsUrl,
                    decoration: InputDecoration(
                      labelText: s.t('Google Maps Link', 'رابط موقع الخريطة (Google Maps)'),
                      hintText: 'https://maps.app.goo.gl/...',
                      prefixIcon: const Icon(Icons.location_on_outlined, color: Colors.redAccent),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _taxCardUrl,
                          decoration: InputDecoration(
                            labelText: s.t('Tax Card Image URL', 'رابط صورة البطاقة الضريبية'),
                            prefixIcon: const Icon(Icons.image),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF008DDA), foregroundColor: Colors.white),
                        icon: _uploadingTaxCard ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.upload_file),
                        label: Text(s.t('Upload', 'رفع صورة')),
                        onPressed: _uploadingTaxCard ? null : _pickAndUploadTaxCard,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.withOpacity(0.3)),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(s.t('Is Parent / Holding Group?', 'هل هي شركة أم / مجموعة رئيسية؟')),
                          value: _isGroup,
                          onChanged: (val) {
                            setState(() {
                              _isGroup = val;
                              if (val) _parentCompanyId = null;
                            });
                          },
                        ),
                        if (!_isGroup) ...[
                          const SizedBox(height: 6),
                          DropdownButtonFormField<String>(
                            value: _parentCompanyId,
                            decoration: InputDecoration(
                              labelText: s.t('Subsidiary of (Select Parent)', 'شركة تابعة لـ (اختر الشركة الأم)'),
                              border: const OutlineInputBorder(),
                            ),
                            items: [
                              DropdownMenuItem<String>(
                                value: null,
                                child: Text(s.t('-- None (Independent) --', '-- لا يوجد (شركة مستقلة) --')),
                              ),
                              ...potentialParents.map((p) {
                                final pName = s.isArabic ? (p['name_ar'] ?? p['name_en'] ?? '') : (p['name_en'] ?? p['name_ar'] ?? '');
                                return DropdownMenuItem<String>(value: p['id'].toString(), child: Text(pName));
                              }),
                            ],
                            onChanged: (val) => setState(() => _parentCompanyId = val),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(s.t('2. Addresses', '٢. العناوين والمقرات'), style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF008DDA))),
                      TextButton.icon(
                        icon: const Icon(Icons.add_location_alt, size: 18),
                        label: Text(s.t('Add Address', 'إضافة عنوان')),
                        onPressed: () => setState(() => _addresses.add({'type': 'mailing', 'en': TextEditingController(), 'ar': TextEditingController()})),
                      ),
                    ],
                  ),
                  ..._addresses.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final a = entry.value;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                DropdownButton<String>(
                                  value: a['type'],
                                  items: [
                                    DropdownMenuItem(value: 'mailing', child: Text(s.t('Mailing / Headquarter', 'عنوان مراسلة / مقر'))),
                                    DropdownMenuItem(value: 'operation', child: Text(s.t('Operation / Factory', 'عنوان تشغيل / مصنع'))),
                                  ],
                                  onChanged: (v) => setState(() => a['type'] = v!),
                                ),
                                const Spacer(),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                  onPressed: () => setState(() => _addresses.removeAt(idx)),
                                ),
                              ],
                            ),
                            TextField(controller: a['en'], decoration: InputDecoration(labelText: s.t('Address (English)', 'العنوان بالإنجليزي'))),
                            const SizedBox(height: 6),
                            TextField(controller: a['ar'], decoration: InputDecoration(labelText: s.t('Address (Arabic)', 'العنوان بالعربي'))),
                          ],
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(s.t('3. Contact Persons', '٣. مسؤولو التواصل'), style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF008DDA))),
                      TextButton.icon(
                        icon: const Icon(Icons.person_add, size: 18),
                        label: Text(s.t('Add Contact', 'إضافة مسؤول')),
                        onPressed: () => setState(() => _contacts.add({
                          'name_en': TextEditingController(),
                          'name_ar': TextEditingController(),
                          'role': TextEditingController(),
                          'phone': TextEditingController(),
                        })),
                      ),
                    ],
                  ),
                  ..._contacts.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final c = entry.value;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(child: TextField(controller: c['name_en'], decoration: InputDecoration(labelText: s.t('Name (EN)', 'الاسم (EN)')))),
                                const SizedBox(width: 8),
                                Expanded(child: TextField(controller: c['name_ar'], decoration: InputDecoration(labelText: s.t('Name (AR)', 'الاسم (عربي)')))),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                  onPressed: () => setState(() => _contacts.removeAt(idx)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(child: TextField(controller: c['role'], decoration: InputDecoration(labelText: s.t('Position / Role', 'المسمى الوظيفي')))),
                                const SizedBox(width: 8),
                                Expanded(child: TextField(controller: c['phone'], decoration: InputDecoration(labelText: s.t('Phone / WhatsApp', 'الهاتف / واتساب')))),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                  if (widget.company != null && widget.onDeleteRequested != null) ...[
                    const Divider(height: 36),
                    ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: const BorderSide(color: Colors.redAccent),
                      ),
                      leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
                      title: Text(
                        s.t('Delete this company', 'حذف هذه الشركة نهائياً'),
                        style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        s.t('Permanently remove this record and its details', 'إزالة هذه الشركة وعناوينها وأرقامها من قاعدة البيانات'),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        widget.onDeleteRequested!();
                      },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF008DDA), foregroundColor: Colors.white),
                onPressed: _saving ? null : _saveAll,
                child: _saving ? const CircularProgressIndicator(color: Colors.white) : Text(s.t('Save Company Record', 'حفظ بيانات الشركة كاملة'), style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------- نافذة الدخول مع خيار Stay Logged In -----------------
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
  String? _error;
  bool _showRequestForm = false;

  final _nameReqController = TextEditingController();
  final _phoneReqController = TextEditingController();

  void _login() async {
    final s = AppState.instance;
    final pin = _pinController.text.trim();
    final pass = _passController.text.trim();

    if (pin.isEmpty || pass.isEmpty) {
      setState(() => _error = s.t('Please enter both PIN and Password', 'برجاء إدخال الكود وكلمة المرور'));
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
        setState(() => _error = s.t('Invalid PIN code', 'كود الدخول غير صحيح'));
      } else {
        if (res['is_first_login'] == true) {
          await Supabase.instance.client.from('app_users').update({
            'password_hash': pass,
            'is_first_login': false,
            'username': 'Admin',
          }).eq('id', res['id']);
          res['username'] = 'Admin';
          res['password_hash'] = pass;

          if (_stayLoggedIn) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('saved_user_session', jsonEncode(res));
          }
          if (mounted) Navigator.pop(context, res);
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
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _submitRequest() async {
    final s = AppState.instance;
    final name = _nameReqController.text.trim();
    final phone = _phoneReqController.text.trim();
    if (name.isEmpty || phone.isEmpty) return;

    await Supabase.instance.client.from('access_requests').insert({
      'full_name': name,
      'phone': phone,
    });

    if (mounted) {
      Navigator.pop(context);
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          content: Text(s.t('Request submitted successfully. Credentials will be sent via WhatsApp.', 'تم إرسال طلبك للإدارة، سيتم إرسال بيانات الدخول عبر الواتساب.')),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _showRequestForm ? s.t('Request New Access', 'طلب انضمام جديد') : s.t('Login', 'تسجيل الدخول'),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            if (!_showRequestForm) ...[
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                autofocus: true,
                textInputAction: TextInputAction.next,
                style: const TextStyle(fontSize: 20, letterSpacing: 4, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: s.t('6-Digit PIN', 'كود الدخول (6 أرقام)'),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passController,
                obscureText: true,
                textAlign: TextAlign.center,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _login(),
                decoration: InputDecoration(
                  hintText: s.t('Password', 'كلمة المرور'),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(s.t('Stay logged in', 'تذكرني (البقاء قيد تسجيل الدخول)')),
                value: _stayLoggedIn,
                onChanged: (v) => setState(() => _stayLoggedIn = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13), textAlign: TextAlign.center),
                ),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF008DDA),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _loading ? null : _login,
                  child: _loading ? const CircularProgressIndicator(color: Colors.white) : Text(s.t('Login', 'تسجيل الدخول'), style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => setState(() => _showRequestForm = true),
                child: Text(s.t('Request a new account', 'طلب حساب مستخدم جديد')),
              ),
            ] else ...[
              TextField(
                controller: _nameReqController,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  hintText: s.t('Full Name', 'الاسم بالكامل'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phoneReqController,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submitRequest(),
                decoration: InputDecoration(
                  hintText: s.t('WhatsApp Phone Number', 'رقم الهاتف (واتساب)'),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF008DDA),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _submitRequest,
                  child: Text(s.t('Submit Request', 'إرسال الطلب')),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _showRequestForm = false),
                child: Text(s.t('Back to login', 'رجوع لتسجيل الدخول')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ----------------- الطباعة الانتقائية -----------------
class SelectivePrintDialog extends StatefulWidget {
  final Map<String, dynamic> company;
  const SelectivePrintDialog({super.key, required this.company});

  @override
  State<SelectivePrintDialog> createState() => _SelectivePrintDialogState();
}

class _SelectivePrintDialogState extends State<SelectivePrintDialog> {
  bool _incName = true;
  bool _incTaxCard = false;
  final Set<String> _selectedAddresses = {};
  final Set<String> _selectedContacts = {};

  @override
  void initState() {
    super.initState();
    final addrs = widget.company['company_addresses'] as List? ?? [];
    for (var a in addrs) {
      _selectedAddresses.add(a['id'].toString());
    }
  }

  void _executePrint() {
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppState.instance.t('Preparing document for printing...', 'تم تجهيز البيانات المحددة للطباعة'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final addrs = widget.company['company_addresses'] as List? ?? [];
    final contacts = widget.company['company_contacts'] as List? ?? [];

    return AlertDialog(
      title: Text(s.t('Selective Print', 'طباعة مخصصة')),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CheckboxListTile(
                title: Text(s.t('Company Name', 'اسم الشركة الرئيسي')),
                value: _incName,
                onChanged: (v) => setState(() => _incName = v ?? true),
              ),
              CheckboxListTile(
                title: Text(s.t('Tax Card Image', 'صورة البطاقة الضريبية')),
                value: _incTaxCard,
                onChanged: (v) => setState(() => _incTaxCard = v ?? false),
              ),
              const Divider(),
              if (addrs.isNotEmpty) ...[
                Text(s.t('Select Addresses:', 'اختر العناوين المطلوب طباعتها:'), style: const TextStyle(fontWeight: FontWeight.bold)),
                ...addrs.map((a) {
                  final text = s.isArabic ? (a['address_ar'] ?? a['address_en'] ?? '') : (a['address_en'] ?? a['address_ar'] ?? '');
                  final id = a['id'].toString();
                  return CheckboxListTile(
                    dense: true,
                    title: Text(text),
                    value: _selectedAddresses.contains(id),
                    onChanged: (v) => setState(() => v == true ? _selectedAddresses.add(id) : _selectedAddresses.remove(id)),
                  );
                }),
                const Divider(),
              ],
              if (contacts.isNotEmpty) ...[
                Text(s.t('Select Contacts:', 'اختر جهات الاتصال:'), style: const TextStyle(fontWeight: FontWeight.bold)),
                ...contacts.map((c) {
                  final name = s.isArabic ? (c['name_ar'] ?? c['name_en'] ?? '') : (c['name_en'] ?? c['name_ar'] ?? '');
                  final id = c['id'].toString();
                  return CheckboxListTile(
                    dense: true,
                    title: Text(name),
                    value: _selectedContacts.contains(id),
                    onChanged: (v) => setState(() => v == true ? _selectedContacts.add(id) : _selectedContacts.remove(id)),
                  );
                }),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('Cancel', 'إلغاء'))),
        ElevatedButton(onPressed: _executePrint, child: Text(s.t('Print', 'طباعة'))),
      ],
    );
  }
}

// ----------------- لوحة تحكم الأدمن والإكسيل المعدل -----------------
class AdminPanelScreen extends StatefulWidget {
  final Map<String, bool> privacy;
  final VoidCallback onUpdate;
  final List<Map<String, dynamic>> companies;

  const AdminPanelScreen({
    super.key,
    required this.privacy,
    required this.onUpdate,
    required this.companies,
  });

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _requests = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _fetchUsers();
    _fetchRequests();
  }

  void _fetchUsers() async {
    final res = await Supabase.instance.client.from('app_users').select().order('created_at');
    setState(() => _users = List<Map<String, dynamic>>.from(res));
  }

  void _fetchRequests() async {
    final res = await Supabase.instance.client
        .from('access_requests')
        .select()
        .eq('status', 'pending')
        .order('created_at', ascending: false);
    setState(() => _requests = List<Map<String, dynamic>>.from(res));
  }

  void _toggleSetting(String key, bool val) async {
    setState(() => widget.privacy[key] = val);
    await Supabase.instance.client.from('system_settings').upsert({
      'key': key,
      'value': val,
    });
    widget.onUpdate();
  }

  // 1. تحميل القالب مع الأعمدة الجديدة
  void _downloadTemplate() {
    var excel = Excel.createExcel();
    Sheet sheet = excel['CompaniesTemplate'];
    excel.delete('Sheet1');

    sheet.appendRow([
      TextCellValue('Company_Name_EN'),
      TextCellValue('Company_Name_AR'),
      TextCellValue('Is_Group (TRUE/FALSE)'),
      TextCellValue('Parent_Company_Name'),
      TextCellValue('Google_Maps_URL'),
      TextCellValue('Address_Type'),
      TextCellValue('Address_EN'),
      TextCellValue('Address_AR'),
      TextCellValue('Contact_Name_EN'),
      TextCellValue('Contact_Name_AR'),
      TextCellValue('Contact_Role'),
      TextCellValue('Contact_Phone'),
      TextCellValue('Tax_Card_URL'),
    ]);

    sheet.appendRow([
      TextCellValue('EGL Logistics Group'),
      TextCellValue('مجموعة المصرية للخدمات اللوجستية'),
      TextCellValue('TRUE'),
      TextCellValue(''),
      TextCellValue('https://maps.app.goo.gl/...'),
      TextCellValue('mailing'),
      TextCellValue('Headquarters, Alexandria'),
      TextCellValue('المقر الرئيسي، الإسكندرية'),
      TextCellValue('Ahmed Hassan'),
      TextCellValue('أحمد حسن'),
      TextCellValue('Group CEO'),
      TextCellValue('+201200000000'),
      TextCellValue('https://...'),
    ]);

    sheet.appendRow([
      TextCellValue('EGL Transport & Customs'),
      TextCellValue('المصرية للنقل والتخليص الجمركي'),
      TextCellValue('FALSE'),
      TextCellValue('EGL Logistics Group'),
      TextCellValue('https://maps.app.goo.gl/...'),
      TextCellValue('operation'),
      TextCellValue('Alexandria Port, Gate 27'),
      TextCellValue('ميناء الإسكندرية، باب 27'),
      TextCellValue('Mohamed Ali'),
      TextCellValue('محمد علي'),
      TextCellValue('Operations Manager'),
      TextCellValue('+201211111111'),
      TextCellValue(''),
    ]);

    final bytes = excel.encode();
    if (bytes != null) {
      _triggerDownloadWeb(bytes, 'corphub_template.xlsx');
    }
  }

  // 2. تصدير كامل البيانات مع الأعمدة الجديدة
  void _exportCurrentData() {
    var excel = Excel.createExcel();
    Sheet sheet = excel['CorpHub_Export'];
    excel.delete('Sheet1');

    sheet.appendRow([
      TextCellValue('Company_Name_EN'),
      TextCellValue('Company_Name_AR'),
      TextCellValue('Is_Group (TRUE/FALSE)'),
      TextCellValue('Parent_Company_Name'),
      TextCellValue('Google_Maps_URL'),
      TextCellValue('Address_Type'),
      TextCellValue('Address_EN'),
      TextCellValue('Address_AR'),
      TextCellValue('Contact_Name_EN'),
      TextCellValue('Contact_Name_AR'),
      TextCellValue('Contact_Role'),
      TextCellValue('Contact_Phone'),
      TextCellValue('Tax_Card_URL'),
    ]);

    final Map<String, String> idToName = {};
    for (var c in widget.companies) {
      idToName[c['id'].toString()] = (c['name_en'] ?? c['name_ar'] ?? '').toString();
    }

    for (var c in widget.companies) {
      final addrs = (c['company_addresses'] as List? ?? []);
      final contacts = (c['company_contacts'] as List? ?? []);
      final maxRows = max(addrs.length, contacts.length);

      final isGroupStr = (c['is_group'] == true) ? 'TRUE' : 'FALSE';
      final parentName = c['parent_company_id'] != null ? (idToName[c['parent_company_id'].toString()] ?? '') : '';
      final mapsUrl = c['google_maps_url'] ?? '';

      if (maxRows == 0) {
        sheet.appendRow([
          TextCellValue(c['name_en'] ?? ''),
          TextCellValue(c['name_ar'] ?? ''),
          TextCellValue(isGroupStr),
          TextCellValue(parentName),
          TextCellValue(mapsUrl),
          TextCellValue(''),
          TextCellValue(''),
          TextCellValue(''),
          TextCellValue(''),
          TextCellValue(''),
          TextCellValue(''),
          TextCellValue(''),
          TextCellValue(c['tax_card_url'] ?? ''),
        ]);
      } else {
        for (int i = 0; i < maxRows; i++) {
          final addr = i < addrs.length ? addrs[i] : null;
          final cont = i < contacts.length ? contacts[i] : null;

          sheet.appendRow([
            TextCellValue(c['name_en'] ?? ''),
            TextCellValue(c['name_ar'] ?? ''),
            TextCellValue(isGroupStr),
            TextCellValue(parentName),
            TextCellValue(mapsUrl),
            TextCellValue(addr?['type'] ?? ''),
            TextCellValue(addr?['address_en'] ?? ''),
            TextCellValue(addr?['address_ar'] ?? ''),
            TextCellValue(cont?['name_en'] ?? ''),
            TextCellValue(cont?['name_ar'] ?? ''),
            TextCellValue(cont?['role_en'] ?? cont?['role_ar'] ?? ''),
            TextCellValue(cont?['phone'] ?? ''),
            TextCellValue(c['tax_card_url'] ?? ''),
          ]);
        }
      }
    }

    final bytes = excel.encode();
    if (bytes != null) {
      _triggerDownloadWeb(bytes, 'corphub_current_data.xlsx');
    }
  }

  void _triggerDownloadWeb(List<int> bytes, String fileName) {
    final base64 = base64Encode(bytes);
    final anchor = 'data:application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;base64,$base64';
    launchUrl(Uri.parse(anchor), mode: LaunchMode.externalApplication);
  }

  // 3. رفع الإكسيل مع نظام Two-Pass Import
  Future<void> _handleExcelUpload({required String mode}) async {
    final s = AppState.instance;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'xls'],
      withData: true,
    );

    if (result == null || result.files.single.bytes == null) return;

    setState(() => _busy = true);

    try {
      final bytes = result.files.single.bytes!;
      final excel = Excel.decodeBytes(bytes);

      if (mode == 'wipe_import') {
        await Supabase.instance.client.from('company_contacts').delete().neq('id', '00000000-0000-0000-0000-000000000000');
        await Supabase.instance.client.from('company_addresses').delete().neq('id', '00000000-0000-0000-0000-000000000000');
        await Supabase.instance.client.from('companies').delete().neq('id', '00000000-0000-0000-0000-000000000000');
      }

      final Map<String, String> companyNameToId = {};
      final List<Map<String, String>> pendingParentLinks = [];

      for (var table in excel.tables.keys) {
        final rows = excel.tables[table]!.rows;
        if (rows.length <= 1) continue;

        // Pass 1: إنشاء وتحديث الشركات والمقرات
        for (int i = 1; i < rows.length; i++) {
          final row = rows[i];
          if (row.isEmpty) continue;

          final nameEn = row.length > 0 ? row[0]?.value?.toString().trim() ?? '' : '';
          final nameAr = row.length > 1 ? row[1]?.value?.toString().trim() ?? '' : '';
          final isGroupVal = row.length > 2 ? row[2]?.value?.toString().trim().toUpperCase() == 'TRUE' : false;
          final parentName = row.length > 3 ? row[3]?.value?.toString().trim() ?? '' : '';
          final mapsUrl = row.length > 4 ? row[4]?.value?.toString().trim() : null;
          final addrType = row.length > 5 ? row[5]?.value?.toString().trim() ?? 'mailing' : 'mailing';
          final addrEn = row.length > 6 ? row[6]?.value?.toString().trim() : null;
          final addrAr = row.length > 7 ? row[7]?.value?.toString().trim() : null;
          final contNameEn = row.length > 8 ? row[8]?.value?.toString().trim() : null;
          final contNameAr = row.length > 9 ? row[9]?.value?.toString().trim() : null;
          final contRole = row.length > 10 ? row[10]?.value?.toString().trim() : null;
          final contPhone = row.length > 11 ? row[11]?.value?.toString().trim() : null;
          final taxCardUrl = row.length > 12 ? row[12]?.value?.toString().trim() : null;

          if (nameEn.isEmpty && nameAr.isEmpty) continue;

          var comp = await Supabase.instance.client
              .from('companies')
              .select()
              .or('name_en.eq."$nameEn",name_ar.eq."$nameAr"')
              .maybeSingle();

          String compId;
          if (comp == null) {
            final ins = await Supabase.instance.client.from('companies').insert({
              'name_en': nameEn.isEmpty ? null : nameEn,
              'name_ar': nameAr.isEmpty ? null : nameAr,
              'is_group': isGroupVal,
              'google_maps_url': mapsUrl,
              'tax_card_url': taxCardUrl,
            }).select().single();
            compId = ins['id'];
          } else {
            compId = comp['id'];
            final Map<String, dynamic> updateData = {'is_group': isGroupVal};
            if (mapsUrl != null && mapsUrl.isNotEmpty) updateData['google_maps_url'] = mapsUrl;
            if (taxCardUrl != null && taxCardUrl.isNotEmpty) updateData['tax_card_url'] = taxCardUrl;
            await Supabase.instance.client.from('companies').update(updateData).eq('id', compId);
          }

          if (nameEn.isNotEmpty) companyNameToId[nameEn.toLowerCase()] = compId;
          if (nameAr.isNotEmpty) companyNameToId[nameAr.toLowerCase()] = compId;

          if (parentName.isNotEmpty) {
            pendingParentLinks.add({'child_id': compId, 'parent_name': parentName.toLowerCase()});
          }

          if ((addrEn != null && addrEn.isNotEmpty) || (addrAr != null && addrAr.isNotEmpty)) {
            await Supabase.instance.client.from('company_addresses').insert({
              'company_id': compId,
              'type': addrType == 'operation' ? 'operation' : 'mailing',
              'address_en': addrEn,
              'address_ar': addrAr,
            });
          }

          if ((contNameEn != null && contNameEn.isNotEmpty) || (contNameAr != null && contNameAr.isNotEmpty)) {
            await Supabase.instance.client.from('company_contacts').insert({
              'company_id': compId,
              'name_en': contNameEn,
              'name_ar': contNameAr,
              'role_en': contRole,
              'role_ar': contRole,
              'phone': contPhone,
            });
          }
        }

        // Pass 2: ربط الفروع بالأصول
        for (var link in pendingParentLinks) {
          final parentId = companyNameToId[link['parent_name']];
          if (parentId != null) {
            await Supabase.instance.client
                .from('companies')
                .update({'parent_company_id': parentId})
                .eq('id', link['child_id']!);
          }
        }
      }

      widget.onUpdate();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.t('Excel data processed with groups successfully!', 'تمت معالجة ملف الإكسيل وربط المجموعات بنجاح!'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _wipeAllData() async {
    final s = AppState.instance;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(s.t('DANGER: Wipe All Companies?', 'تحذير شديد: مسح جميع الشركات؟')),
        content: Text(s.t('This will permanently delete all companies, addresses, and contacts. Are you absolutely sure?', 'سيتم حذف كل الشركات والعناوين والأرقام نهائياً ولا يمكن استرجاعها! هل أنت متأكد؟')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('Cancel', 'إلغاء'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.t('WIPE EVERYTHING', 'مسح الكل نهائياً')),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() => _busy = true);
      await Supabase.instance.client.from('company_contacts').delete().neq('id', '00000000-0000-0000-0000-000000000000');
      await Supabase.instance.client.from('company_addresses').delete().neq('id', '00000000-0000-0000-0000-000000000000');
      await Supabase.instance.client.from('companies').delete().neq('id', '00000000-0000-0000-0000-000000000000');
      widget.onUpdate();
      setState(() => _busy = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('All company data has been wiped.', 'تم تفريغ كافة البيانات.'))));
      }
    }
  }

  void _openAddUserDialog() async {
    final s = AppState.instance;
    final userCtrl = TextEditingController();
    final pinCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    String role = 'editor';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(s.t('Add New User', 'إضافة مستخدم جديد')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: userCtrl, decoration: InputDecoration(hintText: s.t('Username', 'اسم المستخدم'))),
              const SizedBox(height: 10),
              TextField(controller: pinCtrl, keyboardType: TextInputType.number, maxLength: 6, decoration: InputDecoration(counterText: '', hintText: s.t('6-Digit PIN', 'الكود (6 أرقام)'))),
              const SizedBox(height: 10),
              TextField(controller: passCtrl, decoration: InputDecoration(hintText: s.t('Initial Password', 'كلمة المرور الأولية'))),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: role,
                decoration: InputDecoration(labelText: s.t('Role / Permissions', 'الصلاحية والرتبة')),
                items: [
                  DropdownMenuItem(value: 'viewer', child: Text(s.t('Viewer (Read Only)', 'مشاهد (تصفح فقط)'))),
                  DropdownMenuItem(value: 'editor', child: Text(s.t('Editor (Can Add/Edit)', 'محرر (صلاحية إضافة وتعديل)'))),
                  DropdownMenuItem(value: 'admin', child: Text(s.t('Admin (Full Control)', 'مدير نظام (تحكم كامل)'))),
                ],
                onChanged: (val) => setDialogState(() => role = val!),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.t('Cancel', 'إلغاء'))),
            ElevatedButton(
              onPressed: () async {
                if (userCtrl.text.isEmpty || pinCtrl.text.isEmpty) return;
                await Supabase.instance.client.from('app_users').insert({
                  'username': userCtrl.text.trim(),
                  'pin_code': pinCtrl.text.trim(),
                  'password_hash': passCtrl.text.trim(),
                  'role': role,
                  'is_first_login': false,
                  'is_active': true,
                });
                Navigator.pop(ctx);
                _fetchUsers();
              },
              child: Text(s.t('Create User', 'إنشاء المستخدم')),
            ),
          ],
        ),
      ),
    );
  }

  void _updateUserRole(String id, String newRole) async {
    await Supabase.instance.client.from('app_users').update({'role': newRole}).eq('id', id);
    _fetchUsers();
  }

  void _toggleUserActive(String id, bool currentStatus) async {
    await Supabase.instance.client.from('app_users').update({'is_active': !currentStatus}).eq('id', id);
    _fetchUsers();
  }

  void _resetUserPin(Map<String, dynamic> u) async {
    final s = AppState.instance;
    final rand = Random();
    final newPin = (100000 + rand.nextInt(900000)).toString();
    await Supabase.instance.client.from('app_users').update({'pin_code': newPin}).eq('id', u['id']);
    _fetchUsers();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${s.t("New PIN for", "كود الدخول الجديد لـ")} ${u["username"]}: $newPin')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('Admin Control Panel', 'لوحة تحكم الإدارة')),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF008DDA),
          tabs: [
            Tab(icon: const Icon(Icons.table_chart), text: s.t('Excel Operations', 'إدارة الإكسيل')),
            Tab(icon: const Icon(Icons.people), text: s.t('User Panel', 'إدارة المستخدمين')),
            Tab(icon: const Icon(Icons.visibility), text: s.t('Privacy Settings', 'الخصوصية')),
            Tab(icon: const Icon(Icons.mark_email_unread), text: s.t('Requests', 'طلبات الانضمام')),
          ],
        ),
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                // 1. الإكسيل
                ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(s.t('Excel Management & Bulk Import', 'مركز إدارة وتحميل ملفات الإكسيل'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    const SizedBox(height: 16),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.download, color: Colors.blueAccent),
                        title: Text(s.t('Download Excel Template (template.xlsx)', 'تحميل القالب الفارغ (template.xlsx)')),
                        subtitle: Text(s.t('Download template with predefined columns', 'ملف فارغ جاهز بالأعمدة المطلوبة والمجموعات')),
                        trailing: ElevatedButton(onPressed: _downloadTemplate, child: Text(s.t('Download', 'تحميل'))),
                      ),
                    ),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.file_download, color: Colors.teal),
                        title: Text(s.t('Export Current Data to Excel', 'تنزيل الداتا الحالية في إكسيل للتعديل')),
                        subtitle: Text(s.t('Download all stored companies and contacts to edit them on your PC', 'تنزيل كامل الشركات لتعديلها ثم إعادة رفعها')),
                        trailing: ElevatedButton(onPressed: _exportCurrentData, child: Text(s.t('Export', 'تصدير'))),
                      ),
                    ),
                    const Divider(height: 32),
                    Text(s.t('Upload Actions:', 'خيارات الرفع والتحديث:'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF008DDA), foregroundColor: Colors.white, padding: const EdgeInsets.all(16)),
                            icon: const Icon(Icons.add),
                            label: Text(s.t('Append to Existing Data\n(إضافة فوق الحالي)', 'إضافة فوق الحالي')),
                            onPressed: () => _handleExcelUpload(mode: 'append'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.amber.shade800, foregroundColor: Colors.white, padding: const EdgeInsets.all(16)),
                            icon: const Icon(Icons.sync),
                            label: Text(s.t('Update / Merge Data\n(تحديث وتعديل القائم)', 'تحديث وتعديل القائم')),
                            onPressed: () => _handleExcelUpload(mode: 'update'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.deepOrange, foregroundColor: Colors.white, padding: const EdgeInsets.all(16)),
                      icon: const Icon(Icons.delete_sweep),
                      label: Text(s.t('Wipe & Import From Scratch (مسح كامل وإضافة الفايل من الصفر)', 'مسح كامل وإضافة الفايل من الصفر')),
                      onPressed: () => _handleExcelUpload(mode: 'wipe_import'),
                    ),
                    const Divider(height: 40),
                    Card(
                      color: Colors.red.shade900.withOpacity(0.2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.red)),
                      child: ListTile(
                        leading: const Icon(Icons.warning, color: Colors.red),
                        title: Text(s.t('Danger Zone: Wipe All Data', 'منطقة الخطر: مسح وتفريغ الداتا بالكامل'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                        subtitle: Text(s.t('Delete all companies, contacts and addresses from the database', 'مسح كافة الشركات وجهات الاتصال بشكل دائم')),
                        trailing: ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                          onPressed: _wipeAllData,
                          child: Text(s.t('Wipe All', 'مسح الكل')),
                        ),
                      ),
                    ),
                  ],
                ),

                // 2. إدارة المستخدمين
                ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(s.t('System Users & Permissions', 'مستخدمو النظام والصلاحيات'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF008DDA), foregroundColor: Colors.white),
                          icon: const Icon(Icons.person_add),
                          label: Text(s.t('Add User', 'إضافة مستخدم')),
                          onPressed: _openAddUserDialog,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ..._users.map((u) {
                      final isActive = u['is_active'] ?? true;
                      final role = u['role'] ?? 'viewer';

                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: role == 'admin' ? Colors.blue : (role == 'editor' ? Colors.green : Colors.grey),
                            child: Icon(role == 'admin' ? Icons.security : (role == 'editor' ? Icons.edit : Icons.remove_red_eye), color: Colors.white),
                          ),
                          title: Text('${u["username"] ?? "User"} (${u["pin_code"]})'),
                          subtitle: Text('Role: ${role.toUpperCase()} | Active: $isActive'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              DropdownButton<String>(
                                value: role,
                                underline: const SizedBox(),
                                items: const [
                                  DropdownMenuItem(value: 'viewer', child: Text('Viewer')),
                                  DropdownMenuItem(value: 'editor', child: Text('Editor')),
                                  DropdownMenuItem(value: 'admin', child: Text('Admin')),
                                ],
                                onChanged: (newR) {
                                  if (newR != null) _updateUserRole(u['id'], newR);
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.pin),
                                tooltip: s.t('Reset PIN', 'تغيير الكود'),
                                onPressed: () => _resetUserPin(u),
                              ),
                              IconButton(
                                icon: Icon(isActive ? Icons.block : Icons.check_circle, color: isActive ? Colors.orange : Colors.green),
                                tooltip: isActive ? s.t('Disable', 'تعطيل') : s.t('Activate', 'تفعيل'),
                                onPressed: () => _toggleUserActive(u['id'], isActive),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ),

                // 3. الخصوصية
                ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(s.t('Visibility for Non-Logged Users:', 'إعدادات إخفاء وإظهار الأعمدة لغير المسجلين:'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      title: Text(s.t('Allow Public Browsing', 'السماح بالتصفح العام')),
                      value: widget.privacy['allow_public_read'] ?? true,
                      onChanged: (v) => _toggleSetting('allow_public_read', v),
                    ),
                    SwitchListTile(
                      title: Text(s.t('Show Tax Card Image', 'إظهار صورة البطاقة الضريبية')),
                      value: widget.privacy['public_show_tax_card'] ?? false,
                      onChanged: (v) => _toggleSetting('public_show_tax_card', v),
                    ),
                    SwitchListTile(
                      title: Text(s.t('Show Phone Numbers', 'إظهار أرقام الهواتف')),
                      value: widget.privacy['public_show_phones'] ?? false,
                      onChanged: (v) => _toggleSetting('public_show_phones', v),
                    ),
                    SwitchListTile(
                      title: Text(s.t('Show Operation Addresses', 'إظهار عناوين التشغيل والمصانع')),
                      value: widget.privacy['public_show_operation_addresses'] ?? false,
                      onChanged: (v) => _toggleSetting('public_show_operation_addresses', v),
                    ),
                  ],
                ),

                // 4. طلبات الانضمام
                ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(s.t('Pending Access Requests (${_requests.length})', 'طلبات الانضمام المعلقة (${_requests.length})'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    const SizedBox(height: 12),
                    if (_requests.isEmpty)
                      Text(s.t('No pending requests found', 'لا توجد طلبات معلقة حالياً'))
                    else
                      ..._requests.map((r) => Card(
                            child: ListTile(
                              title: Text(r['full_name']),
                              subtitle: Text(r['phone']),
                              trailing: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF25D366), foregroundColor: Colors.white),
                                icon: const Icon(Icons.check, size: 16),
                                label: Text(s.t('Approve & WhatsApp', 'قبول وإرسال واتساب')),
                                onPressed: () async {
                                  final rand = Random();
                                  final pin = (100000 + rand.nextInt(900000)).toString();
                                  final pass = 'Corp@${rand.nextInt(9000) + 1000}';

                                  await Supabase.instance.client.from('app_users').insert({
                                    'username': r['full_name'],
                                    'password_hash': pass,
                                    'pin_code': pin,
                                    'role': 'viewer',
                                    'is_first_login': false,
                                  });

                                  await Supabase.instance.client.from('access_requests').update({'status': 'approved'}).eq('id', r['id']);
                                  _fetchRequests();
                                  _fetchUsers();

                                  final phone = r['phone'].toString().replaceAll(RegExp(r'[^0-9]'), '');
                                  final msg = 'Welcome to CorpHub!\nYour login details are:\nPIN: $pin\nPassword: $pass';
                                  final waUri = Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(msg)}');
                                  if (await canLaunchUrl(waUri)) {
                                    await launchUrl(waUri, mode: LaunchMode.externalApplication);
                                  }
                                },
                              ),
                            ),
                          )),
                  ],
                ),
              ],
            ),
    );
  }
}
