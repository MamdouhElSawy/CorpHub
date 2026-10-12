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
        const eglNavyDark = Color(0xFF0B192C);
        const eglNavyCard = Color(0xFF1E3E62);
        const eglBlueAccent = Color(0xFF008DDA);

        return MaterialApp(
          title: state.isArabic ? 'دليل الشركات' : 'CorpHub - EGL',
          debugShowCheckedModeBanner: false,
          themeMode: state.themeMode,
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
  Map<String, dynamic>? _selectedCompanyForPanel; // للوحة الجانبية على الـ Desktop
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
      barrierDismissible: true,
      builder: (ctx) => Directionality(
        textDirection: s.isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: StatefulBuilder(
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 600, maxHeight: 600),
            padding: const EdgeInsets.all(16),
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
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.picture_as_pdf, size: 64, color: Colors.redAccent),
                                const SizedBox(height: 12),
                                Text(s.t('PDF Document format', 'مستند PDF غير قابل للعرض المباشر هنا')),
                              ],
                            ),
                          )
                        : Image.network(
                            url,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => Center(
                              child: Text(s.t('Failed to load image. Click below to open in browser.', 'تعذر عرض الصورة، اضغط الزر بالأسفل لفتحها مباشرة.')),
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF008DDA), foregroundColor: Colors.white),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: Text(s.t('Open Original / Download', 'فتح الرابط الأصلي / تحميل')),
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

  void _shareTaxCardAsImage(String? url, String companyName) async {
    final s = AppState.instance;
    if (_currentUser == null) return;

    if (url == null || url.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.t('No tax card uploaded', 'لا توجد صورة أو ملف مسجل'))),
      );
      return;
    }

    final isPdf = url.toLowerCase().contains('.pdf');

    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.t('Preparing file for sharing...', 'جاري تجهيز الملف للمشاركة...'))),
      );

      final res = await html.HttpRequest.request(url, responseType: 'blob');
      final blob = res.response as html.Blob;
      final fileName = isPdf ? 'tax_card_${companyName.replaceAll(' ', '_')}.pdf' : 'tax_card_${companyName.replaceAll(' ', '_')}.png';
      final mimeType = isPdf ? 'application/pdf' : 'image/png';
      final file = html.File([blob], fileName, {'type': mimeType});

      if (html.window.navigator.share != null) {
        await html.window.navigator.share({
          'title': '${s.t("Tax Card for", "البطاقة الضريبية لـ")} $companyName',
          'files': [file],
        });
      } else {
        final anchor = html.AnchorElement(href: html.Url.createObjectUrlFromBlob(blob))
          ..setAttribute('download', fileName)
          ..click();
        
        final msg = '${s.t("Tax Card Document for:", "مستند البطاقة الضريبية لشركة:")} $companyName\n\n$url';
        final wa = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(msg)}');
        if (await canLaunchUrl(wa)) {
          await launchUrl(wa, mode: LaunchMode.externalApplication);
        }
      }
    } catch (_) {
      final msg = '${s.t("Tax Card Document for:", "مستند البطاقة الضريبية لشركة:")} $companyName\n\n$url';
      final wa = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(msg)}');
      if (await canLaunchUrl(wa)) {
        await launchUrl(wa, mode: LaunchMode.externalApplication);
      }
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
        elevation: 1,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF008DDA),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('EGL', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
            ),
            const SizedBox(width: 8),
            Text(
              s.t('CorpHub Directory', 'دليل الشركات'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        actions: [
          // زر اللغة الأنيق بدون كلام
          IconButton(
            icon: const Icon(Icons.language, size: 22),
            tooltip: s.isArabic ? 'Switch to English' : 'التحويل إلى العربية',
            onPressed: () {
              s.toggleLanguage();
              setState(() {});
            },
          ),
          // زر المظهر الأنيق بدون كلام
          IconButton(
            icon: Icon(s.themeMode == ThemeMode.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 22),
            tooltip: s.themeMode == ThemeMode.dark ? s.t('Light Theme', 'الوضع النهاري') : s.t('Dark Theme', 'الوضع الليلي'),
            onPressed: () => s.toggleTheme(),
          ),
          const SizedBox(width: 8),
          // زر الحساب أو تسجيل الدخول بشياكة
          if (!isLoggedIn)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF008DDA),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
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
                tooltip: s.t('Account Menu', 'قائمة الحساب'),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Theme.of(context).primaryColor.withOpacity(0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 12,
                        backgroundColor: const Color(0xFF008DDA),
                        child: Text(
                          (_currentUser!['username'] ?? 'U')[0].toString().toUpperCase(),
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _currentUser!['username'] ?? 'User',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const Icon(Icons.arrow_drop_down, size: 18),
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
                          const Icon(Icons.admin_panel_settings, color: Color(0xFF008DDA), size: 20),
                          const SizedBox(width: 8),
                          Text(s.t('Admin Panel', 'لوحة تحكم الإدارة')),
                        ],
                      ),
                    ),
                  PopupMenuItem(
                    value: 'password',
                    child: Row(
                      children: [
                        const Icon(Icons.password, color: Colors.orangeAccent, size: 20),
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
                        const Icon(Icons.logout, color: Colors.redAccent, size: 20),
                        const SizedBox(width: 8),
                        Text(s.t('Logout', 'تسجيل الخروج')),
                      ],
                    ),
                  ),
                ],
              ),
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
          : Row(
              children: [
                // قائمة الشركات في اليسار/اليمين
                Expanded(
                  flex: isDesktop ? 4 : 10,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: s.t('Search company name...', 'ابحث باسم الشركة...'),
                            prefixIcon: const Icon(Icons.search),
                            filled: true,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
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
                                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                                    itemBuilder: (ctx, i) {
                                      final comp = filtered[i];
                                      final isSelected = _selectedCompanyForPanel?['id'] == comp['id'];

                                      return CompanyListTileCard(
                                        company: comp,
                                        allCompanies: _companies,
                                        isLoggedIn: isLoggedIn,
                                        isSelected: isSelected,
                                        onTap: () {
                                          if (isDesktop) {
                                            setState(() => _selectedCompanyForPanel = comp);
                                          } else {
                                            // على الموبايل تفتح شاشة كاملة
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
                // اللوحة الجانبية (Side Panel) للبي سي
                if (isDesktop) ...[
                  const VerticalDivider(width: 1),
                  Expanded(
                    flex: 6,
                    child: _selectedCompanyForPanel == null
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.corporate_fare, size: 64, color: Colors.grey.withOpacity(0.4)),
                                const SizedBox(height: 12),
                                Text(
                                  s.t('Select a company to view details', 'اختر شركة من القائمة لعرض تفاصيلها هنا'),
                                  style: TextStyle(color: Colors.grey.shade500, fontSize: 15),
                                ),
                              ],
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

// ----------------- كارت مصغر للقائمة (List Tile Card) -----------------
class CompanyListTileCard extends StatelessWidget {
  final Map<String, dynamic> company;
  final List<Map<String, dynamic>> allCompanies;
  final bool isLoggedIn;
  final bool isSelected;
  final VoidCallback onTap;

  const CompanyListTileCard({
    super.key,
    required this.company,
    required this.allCompanies,
    required this.isLoggedIn,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final name = s.isArabic ? (company['name_ar'] ?? company['name_en'] ?? '') : (company['name_en'] ?? company['name_ar'] ?? '');
    final isGroup = company['is_group'] == true;

    return Card(
      elevation: isSelected ? 3 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: isSelected ? const Color(0xFF008DDA) : Colors.transparent, width: 1.5),
      ),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: isGroup ? Colors.amber.withOpacity(0.2) : Theme.of(context).primaryColor.withOpacity(0.15),
          child: Icon(
            isGroup ? Icons.account_tree : Icons.corporate_fare,
            color: isGroup ? Colors.amber.shade800 : Theme.of(context).primaryColor,
          ),
        ),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        subtitle: isGroup
            ? Text(s.t('Holding / Group', 'مجموعة قابضة'), style: TextStyle(fontSize: 11, color: Colors.amber.shade800))
            : null,
        trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.grey),
      ),
    );
  }
}

// ----------------- محتوى تفاصيل الشركة المشترك (للـ Side Panel والشاشة الكاملة) -----------------
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

  void _shareMaps(String? url, String companyName) async {
    if (url == null || url.trim().isEmpty) return;
    final msg = '${AppProvider.t("Location for:", "موقع مقر شركة:")} $companyName\n📍 $url';
    final waUri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(msg)}');
    if (await canLaunchUrl(waUri)) {
      await launchUrl(waUri, mode: LaunchMode.externalApplication);
    }
  }

  void _openMaps(String? url) async {
    if (url == null || url.trim().isEmpty) return;
    final uri = Uri.parse(url.trim());
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _shareContact(String cName, String cRole, String phone, String companyName) async {
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

    final showTax = isLoggedIn || (privacy['public_show_tax_card'] ?? false);
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

    String? parentName;
    if (parentId != null) {
      final parent = allCompanies.firstWhere((c) => c['id'] == parentId, orElse: () => {});
      if (parent.isNotEmpty) {
        parentName = s.isArabic ? (parent['name_ar'] ?? parent['name_en']) : (parent['name_en'] ?? parent['name_ar']);
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
                    if (isGroup)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: Colors.amber.withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
                        child: Text(s.t('Holding / Group', 'مجموعة قابضة'), style: TextStyle(fontSize: 12, color: Colors.amber.shade800, fontWeight: FontWeight.bold)),
                      ),
                    if (showRelations && parentName != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('${s.t("Subsidiary of:", "تابعة لمجموعة:")} $parentName', style: TextStyle(fontSize: 13, color: Colors.grey.shade600, fontStyle: FontStyle.italic)),
                      ),
                  ],
                ),
              ),
              if (canEdit) ...[
                IconButton(
                  icon: const Icon(Icons.edit, color: Color(0xFF008DDA)),
                  tooltip: s.t('Edit Company', 'تعديل'),
                  onPressed: onEdit,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  tooltip: s.t('Delete Company', 'حذف'),
                  onPressed: onDelete,
                ),
              ],
            ],
          ),
          const Divider(height: 30),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (company['tax_card_url'] != null) ...[
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF008DDA), foregroundColor: Colors.white),
                  icon: const Icon(Icons.visibility, size: 16),
                  label: Text(s.t('View Tax Card', 'عرض البطاقة الضريبية')),
                  onPressed: onViewTaxCard,
                ),
                if (isLoggedIn)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF25D366), foregroundColor: Colors.white),
                    icon: const Icon(Icons.share, size: 16),
                    label: Text(s.t('Share File (WhatsApp)', 'إرسال بالواتساب')),
                    onPressed: onShare,
                  ),
              ],
              if (isLoggedIn)
                OutlinedButton.icon(
                  icon: const Icon(Icons.print, size: 16),
                  label: Text(s.t('Selective Print', 'طباعة مخصصة')),
                  onPressed: () => showDialog(
                    context: context,
                    barrierDismissible: true,
                    builder: (_) => SelectivePrintDialog(company: company),
                  ),
                ),
            ],
          ),
          const Divider(height: 30),
          if (addresses.isNotEmpty) ...[
            Text(s.t('📍 Addresses & Locations:', '📍 العناوين ومواقع العمل:'), style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).primaryColor, fontSize: 16)),
            const SizedBox(height: 10),
            ...addresses.map((a) {
              final isMail = a['type'] == 'mailing';
              final addrText = s.isArabic ? (a['address_ar'] ?? a['address_en'] ?? '') : (a['address_en'] ?? a['address_ar'] ?? '');
              final mapUrl = isLoggedIn ? a['map_url']?.toString() : null; // إخفاء الخريطة لغير المسجل

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text('• [${isMail ? s.t("Mailing", "مراسلة") : s.t("Operation", "تشغيل")}]: $addrText', style: const TextStyle(fontSize: 14)),
                    ),
                    if (isLoggedIn && mapUrl != null && mapUrl.trim().isNotEmpty) ...[
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => _openMaps(mapUrl),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: Colors.redAccent.withOpacity(0.15), borderRadius: BorderRadius.circular(6)),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.location_on, size: 14, color: Colors.redAccent),
                              SizedBox(width: 4),
                              Text('خريطة', style: TextStyle(fontSize: 12, color: Colors.redAccent, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }),
            const SizedBox(height: 20),
          ],
          if (contacts.isNotEmpty) ...[
            Text(s.t('👤 Contacts & Personnel:', '👤 مسؤولو التواصل:'), style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).primaryColor, fontSize: 16)),
            const SizedBox(height: 10),
            ...contacts.map((c) {
              final cName = s.isArabic ? (c['name_ar'] ?? c['name_en'] ?? '') : (c['name_en'] ?? c['name_ar'] ?? '');
              // غير المسجل: المسمى الوظيفي يتحول لـ **** والتليفون يتحول لـ ****
              final cRole = isLoggedIn ? (s.isArabic ? (c['role_ar'] ?? c['role_en'] ?? '') : (c['role_en'] ?? c['role_ar'] ?? '')) : '****';
              final phone = isLoggedIn ? (c['phone'] ?? '') : '****';

              return Card(
                elevation: 0,
                color: Theme.of(context).cardColor.withOpacity(0.5),
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Colors.grey.withOpacity(0.2))),
                child: ListTile(
                  dense: true,
                  title: Text(cName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  subtitle: Text('$cRole\n$phone', style: const TextStyle(fontSize: 13)),
                  trailing: isLoggedIn
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.share, size: 18, color: Color(0xFF25D366)),
                              tooltip: s.t('Share Contact', 'مشاركة بيانات المسؤول'),
                              onPressed: () => _shareContact(cName, cRole, phone, name),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy, size: 18),
                              tooltip: s.t('Copy', 'نسخ'),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: "Name: $cName\nRole: $cRole\nPhone: $phone"));
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('Copied!', 'تم النسخ!'))));
                              },
                            ),
                          ],
                        )
                      : null,
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}

// ----------------- اللوحة الجانبية للـ Desktop (Side Panel) -----------------
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
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(left: BorderSide(color: Colors.grey.withOpacity(0.2))),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(bottom: BorderSide(color: Colors.grey.withOpacity(0.2))),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: AppState.instance.t('Close Panel', 'إغلاق اللوحة'),
                  onPressed: onClose,
                ),
              ],
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
      ),
    );
  }
}

// ----------------- شاشة تفاصيل الشركة للموبايل (Full Screen) -----------------
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
    final s = AppState.instance;
    final name = s.isArabic ? (company['name_ar'] ?? company['name_en'] ?? '') : (company['name_en'] ?? company['name_ar'] ?? '');

    return Scaffold(
      appBar: AppBar(
        title: Text(name),
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
        onShare: onShare,
      ),
    );
  }
}

class AppProvider {
  static String t(String en, String ar) => AppState.instance.isArabic ? ar : en;
}

// ----------------- استمارة إضافة وتعديل الشركة -----------------
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

  bool _partOfGroup = false;
  bool _isGroupMother = false;
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

      final bool isGrp = widget.company!['is_group'] == true;
      final String? pId = widget.company!['parent_company_id'];

      if (isGrp) {
        _partOfGroup = true;
        _isGroupMother = true;
        _parentCompanyId = null;
      } else if (pId != null) {
        _partOfGroup = true;
        _isGroupMother = false;
        _parentCompanyId = pId;
      } else {
        _partOfGroup = false;
        _isGroupMother = false;
        _parentCompanyId = null;
      }

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
    final s = AppState.instance;
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
      
      if (!isPdf) {
        try {
          final codec = await ui.instantiateImageCodec(fileBytes, targetWidth: 1200);
          final frame = await codec.getNextFrame();
          final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
          if (data != null) {
            fileBytes = data.buffer.asUint8List();
          }
        } catch (_) {}
      }

      final fileName = 'tax_card_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final contentType = isPdf ? 'application/pdf' : 'image/png';

      await Supabase.instance.client.storage.from('tax-cards').uploadBinary(
            fileName,
            fileBytes,
            fileOptions: FileOptions(upsert: true, contentType: contentType),
          );

      final publicUrl = Supabase.instance.client.storage.from('tax-cards').getPublicUrl(fileName);
      setState(() {
        _taxCardUrl.text = publicUrl;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.t('Tax card compressed & uploaded successfully!', 'تم ضغط ورفع مستند البطاقة الضريبية بنجاح!'))),
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
      final bool finalIsGroup = _partOfGroup && _isGroupMother;
      final String? finalParentId = (_partOfGroup && !_isGroupMother) ? _parentCompanyId : null;

      final compData = {
        'name_en': en.isEmpty ? null : en,
        'name_ar': ar.isEmpty ? null : ar,
        'tax_card_url': _taxCardUrl.text.trim().isEmpty ? null : _taxCardUrl.text.trim(),
        'is_group': finalIsGroup,
        'parent_company_id': finalParentId,
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
      insetPadding: widget.isMobile ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(widget.isMobile ? 0 : 16)),
      child: Container(
        width: widget.isMobile ? double.infinity : 680,
        height: widget.isMobile ? double.infinity : 760,
        padding: EdgeInsets.all(widget.isMobile ? 16 : 24),
        child: Column(
          children: [
            Row(
              children: [
                Icon(widget.company == null ? Icons.add_business : Icons.edit, color: const Color(0xFF008DDA)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.company == null ? s.t('Register New Company', 'تسجيل شركة جديدة') : s.t('Edit Company Details', 'تعديل بيانات الشركة'),
                    style: TextStyle(fontSize: widget.isMobile ? 16 : 18, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView(
                children: [
                  TextField(controller: _nameEn, decoration: InputDecoration(labelText: s.t('Name (English)', 'الاسم بالإنجليزية'))),
                  const SizedBox(height: 10),
                  TextField(controller: _nameAr, decoration: InputDecoration(labelText: s.t('Name (Arabic)', 'الاسم بالعربية'))),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(controller: _taxCardUrl, decoration: InputDecoration(labelText: s.t('Tax Card URL', 'رابط البطاقة أو الـ PDF'))),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF008DDA), foregroundColor: Colors.white),
                        icon: _uploadingTaxCard ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.upload_file),
                        label: Text(s.t('Upload', 'رفع')),
                        onPressed: _uploadingTaxCard ? null : _pickAndUploadTaxCard,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  ..._addresses.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final a = entry.value;
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          children: [
                            TextField(controller: a['en'], decoration: InputDecoration(labelText: s.t('Address (EN)', 'العنوان EN'))),
                            TextField(controller: a['ar'], decoration: InputDecoration(labelText: s.t('Address (AR)', 'العنوان عربي'))),
                            TextField(controller: a['map_url'], decoration: InputDecoration(labelText: s.t('Map URL', 'رابط الخريطة'))),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF008DDA), foregroundColor: Colors.white),
                onPressed: _saving ? null : _saveAll,
                child: _saving ? const CircularProgressIndicator(color: Colors.white) : Text(s.t('Save Company Record', 'حفظ الشركة'), style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------- نافذة تسجيل الدخول (Clean Login Dialog المحسنة) -----------------
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
        setState(() => _error = s.t('Invalid PIN or account disabled', 'كود الدخول غير صحيح أو الحساب معطل'));
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

  void _submitAccountRequest() async {
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
        barrierDismissible: true,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, color: Color(0xFF25D366), size: 56),
              const SizedBox(height: 12),
              Text(
                s.t('Request submitted successfully. Credentials will be sent via WhatsApp.', 'تم إرسال طلبك للإدارة بنجاح، وسيتم إرسال بيانات الدخول عبر الواتساب فور الموافقة.'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15),
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF008DDA), foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(context),
              child: const Text('حسناً'),
            ),
          ],
        ),
      );
    }
  }

  void _submitPasswordResetRequest() async {
    final s = AppState.instance;
    final pin = _resetPinController.text.trim();
    final phone = _resetPhoneController.text.trim();
    final newPass = _resetNewPassController.text.trim();

    if (pin.isEmpty || phone.isEmpty || newPass.isEmpty) {
      setState(() => _error = s.t('Please fill all fields', 'برجاء ملء كافة البيانات'));
      return;
    }

    setState(() => _loading = true);

    try {
      await Supabase.instance.client.from('password_resets').insert({
        'pin_code': pin,
        'phone': phone,
        'new_password': newPass,
      });

      if (mounted) {
        Navigator.pop(context);
        showDialog(
          context: context,
          barrierDismissible: true,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle, color: Color(0xFF25D366), size: 56),
                const SizedBox(height: 12),
                Text(
                  s.t('Reset request submitted. Once approved by admin, your new password will be activated.', 'تم إرسال طلب تعيين كلمة المرور بنجاح، وسيتم تفعيلها فور مصادقة الإدارة عليها.'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15),
                ),
              ],
            ),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF008DDA), foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(context),
                child: const Text('حسناً'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _viewMode == 0
                      ? s.t('Login', 'تسجيل الدخول')
                      : _viewMode == 1
                          ? s.t('Request New Access', 'طلب انضمام جديد')
                          : s.t('Request Password Reset', 'طلب استعادة كلمة المرور'),
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF008DDA)),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 20),

            if (_viewMode == 0) ...[
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                autofocus: true,
                style: const TextStyle(fontSize: 20, letterSpacing: 6, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: s.t('6-Digit PIN', 'كود الدخول (6 أرقام)'),
                  prefixIcon: const Icon(Icons.pin),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _passController,
                obscureText: true,
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  hintText: s.t('Password', 'كلمة المرور'),
                  prefixIcon: const Icon(Icons.lock),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13), textAlign: TextAlign.center),
                ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF008DDA),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _loading ? null : _login,
                  child: _loading ? const CircularProgressIndicator(color: Colors.white) : Text(s.t('Login', 'تسجيل الدخول'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => setState(() { _error = null; _viewMode = 2; }),
                    child: Text(s.t('Forgot Password?', 'نسيت كلمة المرور؟')),
                  ),
                  TextButton(
                    onPressed: () => setState(() { _error = null; _viewMode = 1; }),
                    child: Text(s.t('Request Account', 'طلب حساب جديد')),
                  ),
                ],
              ),
            ] else if (_viewMode == 1) ...[
              TextField(
                controller: _nameReqController,
                decoration: InputDecoration(
                  hintText: s.t('Full Name', 'الاسم بالكامل'),
                  prefixIcon: const Icon(Icons.person),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _phoneReqController,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  hintText: s.t('WhatsApp Phone Number', 'رقم الهاتف (واتساب)'),
                  prefixIcon: const Icon(Icons.phone),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF008DDA),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _submitAccountRequest,
                  child: Text(s.t('Submit Request', 'إرسال الطلب'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
              TextButton(
                onPressed: () => setState(() { _error = null; _viewMode = 0; }),
                child: Text(s.t('Back to login', 'رجوع لتسجيل الدخول')),
              ),
            ] else if (_viewMode == 2) ...[
              TextField(
                controller: _resetPinController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  counterText: '',
                  hintText: s.t('6-Digit PIN Code', 'كود الدخول (6 أرقام)'),
                  prefixIcon: const Icon(Icons.pin),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _resetPhoneController,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  hintText: s.t('Registered Phone', 'رقم الهاتف المسجل'),
                  prefixIcon: const Icon(Icons.phone),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _resetNewPassController,
                obscureText: true,
                decoration: InputDecoration(
                  hintText: s.t('New Password', 'كلمة المرور الجديدة المطلوبة'),
                  prefixIcon: const Icon(Icons.lock),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber.shade800,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _loading ? null : _submitPasswordResetRequest,
                  child: _loading ? const CircularProgressIndicator(color: Colors.white) : Text(s.t('Submit Reset Request', 'إرسال طلب التعيين للإدارة'), style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              TextButton(
                onPressed: () => setState(() { _error = null; _viewMode = 0; }),
                child: Text(s.t('Back to login', 'رجوع لتسجيل الدخول')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ----------------- الطباعة الانتقائية المطورة -----------------
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
    final contacts = widget.company['company_contacts'] as List? ?? [];
    for (var c in contacts) {
      _selectedContacts.add(c['id'].toString());
    }
  }

  void _executePrint() {
    final s = AppState.instance;
    final comp = widget.company;
    final compName = s.isArabic
        ? (comp['name_ar'] ?? comp['name_en'] ?? '')
        : (comp['name_en'] ?? comp['name_ar'] ?? '');

    final addrs = (comp['company_addresses'] as List? ?? [])
        .where((a) => _selectedAddresses.contains(a['id'].toString()))
        .toList();

    final contacts = (comp['company_contacts'] as List? ?? [])
        .where((c) => _selectedContacts.contains(c['id'].toString()))
        .toList();

    String contentHtml = '''
      <!DOCTYPE html>
      <html dir="${s.isArabic ? 'rtl' : 'ltr'}">
      <head>
        <meta charset="utf-8">
        <title>CorpHub - $compName</title>
        <style>
          @page { size: A4; margin: 15mm; }
          body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; color: #111; margin: 0; padding: 10px; background: #fff; }
          .header { text-align: center; border-bottom: 2px solid #008DDA; padding-bottom: 12px; margin-bottom: 20px; }
          .header h1 { margin: 0; font-size: 22px; color: #0B192C; }
          .sub-title { font-size: 11px; color: #666; margin-top: 4px; }
          .section { margin-bottom: 18px; }
          .section-title { font-weight: bold; font-size: 15px; color: #008DDA; border-bottom: 1px solid #ddd; padding-bottom: 4px; margin-bottom: 8px; }
          .item { font-size: 13px; margin-bottom: 6px; line-height: 1.5; }
          .page-break { page-break-before: always; break-before: page; }
          .tax-card-wrapper { display: flex; flex-direction: column; align-items: center; justify-content: flex-start; width: 100%; margin-top: 20px; }
          .printable-card { width: 9cm; height: 5cm; object-fit: contain; border: 1px solid #999; border-radius: 6px; padding: 4px; background: #fff; }
          .printable-pdf { width: 100%; max-width: 18cm; height: 22cm; border: 1px solid #ccc; border-radius: 4px; }
          @media print { body { padding: 0; background: none; } .printable-card { border: 1px solid #333 !important; } }
        </style>
      </head>
      <body>
        <div class="header">
          ${_incName ? "<h1>$compName</h1>" : ""}
          <div class="sub-title">CorpHub Corporate Directory Report</div>
        </div>
    ''';

    if (addrs.isNotEmpty) {
      contentHtml += '<div class="section"><div class="section-title">${s.t("Addresses:", "العناوين:")}</div>';
      for (var a in addrs) {
        final text = s.isArabic ? (a['address_ar'] ?? a['address_en'] ?? '') : (a['address_en'] ?? a['address_ar'] ?? '');
        final type = a['type'] == 'mailing' ? s.t('Mailing', 'مراسلة') : s.t('Operation', 'تشغيل');
        contentHtml += '<div class="item">• <b>[$type]:</b> $text</div>';
      }
      contentHtml += '</div>';
    }

    if (contacts.isNotEmpty) {
      contentHtml += '<div class="section"><div class="section-title">${s.t("Contacts:", "جهات الاتصال:")}</div>';
      for (var c in contacts) {
        final cName = s.isArabic ? (c['name_ar'] ?? c['name_en'] ?? '') : (c['name_en'] ?? c['name_ar'] ?? '');
        final cRole = s.isArabic ? (c['role_ar'] ?? c['role_en'] ?? '') : (c['role_en'] ?? c['role_ar'] ?? '');
        final phone = c['phone'] ?? '';
        contentHtml += '<div class="item">• <b>$cName</b> ($cRole) - $phone</div>';
      }
      contentHtml += '</div>';
    }

    if (_incTaxCard && comp['tax_card_url'] != null) {
      final url = comp['tax_card_url'].toString();
      final isPdf = url.toLowerCase().contains('.pdf');

      contentHtml += '''
        <div class="page-break"></div>
        <div class="tax-card-wrapper">
          <div class="section-title" style="width: 100%; text-align: center; margin-bottom: 15px;">
            ${s.t("Tax Card Document:", "مستند البطاقة الضريبية:")}
          </div>
      ''';

      if (!isPdf) {
        contentHtml += '<img class="printable-card" src="$url" />';
      } else {
        contentHtml += '''
          <object class="printable-pdf" data="$url#toolbar=0&navpanes=0&scrollbar=0" type="application/pdf">
            <embed src="$url#toolbar=0&navpanes=0&scrollbar=0" type="application/pdf" />
          </object>
        ''';
      }

      contentHtml += '</div>';
    }

    contentHtml += '''
        <script>
          window.onload = function() {
            setTimeout(function() {
              window.print();
            }, 500);
          };
        </script>
      </body>
      </html>
    ''';

    final blob = html.Blob([contentHtml], 'text/html');
    final blobUrl = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(blobUrl, '_blank');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final addrs = widget.company['company_addresses'] as List? ?? [];
    final contacts = widget.company['company_contacts'] as List? ?? [];

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                title: Text(s.t('Tax Card / PDF (Dedicated Page)', 'البطاقة الضريبية / مستند مستقل بالطباعة')),
                value: _incTaxCard,
                onChanged: (v) => setState(() => _incTaxCard = v ?? false),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('Cancel', 'إلغاء'))),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF008DDA), foregroundColor: Colors.white),
          onPressed: _executePrint,
          child: Text(s.t('Print', 'طباعة')),
        ),
      ],
    );
  }
}

// ----------------- لوحة تحكم الأدمن -----------------
class AdminPanelScreen extends StatefulWidget {
  final Map<String, bool> privacy;
  final VoidCallback onUpdate;
  final List<Map<String, dynamic>> companies;
  final String? currentUserId;

  const AdminPanelScreen({
    super.key,
    required this.privacy,
    required this.onUpdate,
    required this.companies,
    this.currentUserId,
  });

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _requests = [];
  List<Map<String, dynamic>> _resets = [];
  bool _busy = false;

  RealtimeChannel? _adminChannel;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _fetchUsers();
    _fetchRequests();
    _fetchResets();
    _setupAdminRealtime();
  }

  @override
  void dispose() {
    if (_adminChannel != null) {
      Supabase.instance.client.removeChannel(_adminChannel!);
    }
    super.dispose();
  }

  void _setupAdminRealtime() {
    _adminChannel = Supabase.instance.client
        .channel('public:admin_feed')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'access_requests',
          callback: (_) => _fetchRequests(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'password_resets',
          callback: (_) => _fetchResets(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'app_users',
          callback: (_) => _fetchUsers(),
        )
        .subscribe();
  }

  void _fetchUsers() async {
    try {
      final res = await Supabase.instance.client.from('app_users').select().order('created_at');
      if (mounted) setState(() => _users = List<Map<String, dynamic>>.from(res));
    } catch (_) {}
  }

  void _fetchRequests() async {
    try {
      final res = await Supabase.instance.client
          .from('access_requests')
          .select()
          .order('created_at', ascending: false);
      if (mounted) setState(() => _requests = List<Map<String, dynamic>>.from(res));
    } catch (_) {}
  }

  void _fetchResets() async {
    try {
      final res = await Supabase.instance.client
          .from('password_resets')
          .select()
          .order('created_at', ascending: false);
      if (mounted) setState(() => _resets = List<Map<String, dynamic>>.from(res));
    } catch (_) {}
  }

  void _openAddUserDialog() async {
    final s = AppState.instance;
    final userCtrl = TextEditingController();
    final pinCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    String role = 'editor';

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(s.t('Add New User', 'إضافة مستخدم جديد')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: userCtrl, decoration: InputDecoration(hintText: s.t('Username', 'اسم المستخدم'))),
              const SizedBox(height: 10),
              TextField(controller: pinCtrl, keyboardType: TextInputType.number, maxLength: 6, decoration: InputDecoration(counterText: '', hintText: s.t('6-Digit PIN', 'كود الدخول (6 أرقام)'))),
              const SizedBox(height: 10),
              TextField(controller: passCtrl, decoration: InputDecoration(hintText: s.t('Password', 'كلمة المرور'))),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: role,
                decoration: InputDecoration(labelText: s.t('Role', 'الصلاحية')),
                items: const [
                  DropdownMenuItem(value: 'viewer', child: Text('مشاهد')),
                  DropdownMenuItem(value: 'editor', child: Text('محرر')),
                  DropdownMenuItem(value: 'admin', child: Text('مدير نظام')),
                ],
                onChanged: (val) => setDialogState(() => role = val!),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.t('Cancel', 'إلغاء'))),
            ElevatedButton(
              onPressed: () async {
                if (userCtrl.text.trim().isEmpty || pinCtrl.text.trim().isEmpty) return;
                await Supabase.instance.client.from('app_users').insert({
                  'username': userCtrl.text.trim(),
                  'pin_code': pinCtrl.text.trim(),
                  'password_hash': passCtrl.text.trim().isEmpty ? '123456' : passCtrl.text.trim(),
                  'role': role,
                  'is_first_login': false,
                  'is_active': true,
                });
                Navigator.pop(ctx);
                _fetchUsers();
              },
              child: Text(s.t('Create', 'إنشاء')),
            ),
          ],
        ),
      ),
    );
  }

  void _downloadTemplate() {
    var excel = Excel.createExcel();
    Sheet sheet = excel['CompaniesTemplate'];
    excel.delete('Sheet1');
    sheet.appendRow([TextCellValue('Company_Name_EN'), TextCellValue('Company_Name_AR')]);
    final bytes = excel.encode();
    if (bytes != null) {
      final base64 = base64Encode(bytes);
      launchUrl(Uri.parse('data:application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;base64,$base64'), mode: LaunchMode.externalApplication);
    }
  }

  void _exportCurrentData() {
    var excel = Excel.createExcel();
    Sheet sheet = excel['CorpHub_Export'];
    excel.delete('Sheet1');
    sheet.appendRow([TextCellValue('Company_Name_EN'), TextCellValue('Company_Name_AR')]);
    for (var c in widget.companies) {
      sheet.appendRow([TextCellValue(c['name_en'] ?? ''), TextCellValue(c['name_ar'] ?? '')]);
    }
    final bytes = excel.encode();
    if (bytes != null) {
      final base64 = base64Encode(bytes);
      launchUrl(Uri.parse('data:application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;base64,$base64'), mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('Admin Control Panel', 'لوحة تحكم الإدارة')),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: [
            Tab(icon: const Icon(Icons.table_chart), text: s.t('Excel Operations', 'الإكسيل')),
            Tab(icon: const Icon(Icons.people), text: s.t('User Panel', 'المستخدمين')),
            Tab(icon: const Icon(Icons.lock_reset), text: s.t('Resets', 'الاستعادة')),
            Tab(icon: const Icon(Icons.mark_email_unread), text: s.t('Requests', 'الطلبات')),
          ],
        ),
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.download, color: Colors.blueAccent),
                        title: Text(s.t('Download Template', 'تحميل قالب الإكسيل')),
                        trailing: ElevatedButton(onPressed: _downloadTemplate, child: Text(s.t('Download', 'تحميل'))),
                      ),
                    ),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.file_download, color: Colors.teal),
                        title: Text(s.t('Export Data', 'تصدير الداتا الحالية')),
                        trailing: ElevatedButton(onPressed: _exportCurrentData, child: Text(s.t('Export', 'تصدير'))),
                      ),
                    ),
                  ],
                ),
                ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(s.t('System Users', 'مستخدمو النظام'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF008DDA), foregroundColor: Colors.white),
                          icon: const Icon(Icons.person_add),
                          label: Text(s.t('Add User', 'إضافة مستخدم')),
                          onPressed: _openAddUserDialog,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ..._users.map((u) => Card(
                          child: ListTile(
                            title: Text('${u["username"]} (PIN: ${u["pin_code"]})', style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text('Role: ${u["role"]}'),
                          ),
                        )),
                  ],
                ),
                ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(s.t('Password Resets', 'طلبات استعادة كلمة المرور'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    const SizedBox(height: 12),
                    ..._resets.map((r) => Card(child: ListTile(title: Text('PIN: ${r["pin_code"]} - Phone: ${r["phone"]}')))),
                  ],
                ),
                ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(s.t('Access Requests', 'طلبات الانضمام'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    const SizedBox(height: 12),
                    ..._requests.map((req) => Card(child: ListTile(title: Text('${req["full_name"]} (${req["phone"]})')))),
                  ],
                ),
              ],
            ),
    );
  }
}
