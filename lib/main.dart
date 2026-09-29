import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var supabaseUrl = const String.fromEnvironment('SUPABASE_URL').trim();
  final supabaseAnonKey = const String.fromEnvironment('SUPABASE_ANON_KEY').trim();

  // تنظيف الرابط تلقائياً من أي شرطات أو مسارات زائدة
  if (supabaseUrl.endsWith('/')) {
    supabaseUrl = supabaseUrl.substring(0, supabaseUrl.length - 1);
  }
  if (supabaseUrl.endsWith('/rest/v1')) {
    supabaseUrl = supabaseUrl.replaceAll('/rest/v1', '');
  }

  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const CorpHubApp());
}

// ----------------- إدارة اللغات والمظهر وهيكل EGL -----------------
class AppState extends ChangeNotifier {
  static final AppState instance = AppState._();
  AppState._();

  bool isArabic = false; // الأساسي إنجليزي بناء على طلبك
  ThemeMode themeMode = ThemeMode.dark;

  void toggleLanguage() {
    isArabic = !isArabic;
    notifyListeners();
  }

  void toggleTheme(bool dark) {
    themeMode = dark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
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

        // باليتة ألوان EGL الرسمية
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
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
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
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: const Color(0xFF132A46),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
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
    _loadAll();
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
          .select('*, company_addresses(*), company_contacts(*), related_companies(*)')
          .order('created_at', ascending: false);
      _companies = List<Map<String, dynamic>>.from(res);
    } catch (_) {}
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
                        MaterialPageRoute(builder: (_) => AdminPanelScreen(privacy: _privacy, onUpdate: _loadAll)),
                      );
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.logout, color: Colors.redAccent),
                  title: Text('${s.t("Logout", "خروج")} (${_currentUser!["username"] ?? ""})'),
                  onTap: () {
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

  void _shareOnWhatsApp(String? url, String companyName) async {
    final s = AppState.instance;
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.t('No image registered', 'لا توجد صورة مسجلة'))),
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
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('EGL', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white)),
            ),
            const SizedBox(width: 10),
            Text(s.t('CorpHub Directory', 'دليل الشركات'), style: const TextStyle(fontWeight: FontWeight.bold)),
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
      body: !canBrowse
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.lock_outline, size: 64, color: Color(0xFF008DDA)),
                  const SizedBox(height: 16),
                  Text(s.t('Browsing is restricted to authorized members', 'التصفح مغلق لغير المسجلين'), style: const TextStyle(fontSize: 18)),
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
                    ),
                    onChanged: (val) => setState(() => _searchQuery = val),
                  ),
                ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : filtered.isEmpty
                          ? Center(child: Text(s.t('No records found', 'لا توجد بيانات مسجلة')))
                          : ListView.separated(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 12),
                              itemBuilder: (ctx, i) {
                                final comp = filtered[i];
                                return CompanyCard(
                                  company: comp,
                                  isLoggedIn: isLoggedIn,
                                  privacy: _privacy,
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

// ----------------- كارت الشركة بتصميم EGL -----------------
class CompanyCard extends StatelessWidget {
  final Map<String, dynamic> company;
  final bool isLoggedIn;
  final Map<String, bool> privacy;
  final VoidCallback onShare;

  const CompanyCard({
    super.key,
    required this.company,
    required this.isLoggedIn,
    required this.privacy,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final name = s.isArabic ? (company['name_ar'] ?? company['name_en'] ?? '') : (company['name_en'] ?? company['name_ar'] ?? '');

    final showTax = isLoggedIn || (privacy['public_show_tax_card'] ?? false);
    final showPhones = isLoggedIn || (privacy['public_show_phones'] ?? false);
    final showMailing = isLoggedIn || (privacy['public_show_mailing_addresses'] ?? true);
    final showOps = isLoggedIn || (privacy['public_show_operation_addresses'] ?? false);

    final addresses = (company['company_addresses'] as List? ?? []).where((a) {
      if (a['type'] == 'mailing') return showMailing;
      if (a['type'] == 'operation') return showOps;
      return true;
    }).toList();

    final contacts = (company['company_contacts'] as List? ?? []);

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).primaryColor.withOpacity(0.15),
          child: Icon(Icons.corporate_fare, color: Theme.of(context).primaryColor),
        ),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (showTax && company['tax_card_url'] != null) ...[
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF25D366), foregroundColor: Colors.white),
                        icon: const Icon(Icons.share, size: 16),
                        label: Text(s.t('WhatsApp Card', 'واتساب البطاقة')),
                        onPressed: onShare,
                      ),
                      const SizedBox(width: 8),
                    ],
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
                  Text(s.t('👤 Contacts & Representatives:', '👤 جهات الاتصال:'), style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).primaryColor)),
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
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: c['phone'] ?? ''));
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('Copied to clipboard', 'تم النسخ'))));
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

// ----------------- نافذة الدخول مع دعم زر Enter -----------------
class CleanLoginDialog extends StatefulWidget {
  const CleanLoginDialog({super.key});

  @override
  State<CleanLoginDialog> createState() => _CleanLoginDialogState();
}

class _CleanLoginDialogState extends State<CleanLoginDialog> {
  final _pinController = TextEditingController();
  final _passController = TextEditingController();
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
        }
        if (mounted) Navigator.pop(context, res);
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
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passController,
                obscureText: true,
                textAlign: TextAlign.center,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _login(), // الضغط على Enter ينفذ الدخول مباشرة
                decoration: InputDecoration(
                  hintText: s.t('Password', 'كلمة المرور'),
                ),
              ),
              const SizedBox(height: 16),
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
                  child: _loading ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Text(s.t('Login', 'تسجيل الدخول'), style: const TextStyle(fontWeight: FontWeight.bold)),
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
                onSubmitted: (_) => _submitRequest(), // Enter يرسل الطلب مباشرة
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
      SnackBar(content: Text(AppState.instance.t('Preparing selected document for printing...', 'تم تجهيز البيانات المحددة للطباعة'))),
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
                Text(s.t('Select Addresses to Include:', 'اختر العناوين المطلوب طباعتها:'), style: const TextStyle(fontWeight: FontWeight.bold)),
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
                Text(s.t('Select Contacts to Include:', 'اختر جهات الاتصال:'), style: const TextStyle(fontWeight: FontWeight.bold)),
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

// ----------------- لوحة تحكم الأدمن -----------------
class AdminPanelScreen extends StatefulWidget {
  final Map<String, bool> privacy;
  final VoidCallback onUpdate;
  const AdminPanelScreen({super.key, required this.privacy, required this.onUpdate});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  List<Map<String, dynamic>> _requests = [];

  @override
  void initState() {
    super.initState();
    _fetchRequests();
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

  void _approveRequest(Map<String, dynamic> req) async {
    final rand = Random();
    final pin = (100000 + rand.nextInt(900000)).toString();
    final pass = 'Corp@${rand.nextInt(9000) + 1000}';

    await Supabase.instance.client.from('app_users').insert({
      'username': req['full_name'],
      'password_hash': pass,
      'pin_code': pin,
      'role': 'viewer',
      'is_first_login': false,
    });

    await Supabase.instance.client
        .from('access_requests')
        .update({'status': 'approved'})
        .eq('id', req['id']);

    _fetchRequests();

    final phone = req['phone'].toString().replaceAll(RegExp(r'[^0-9]'), '');
    final msg = 'Welcome to CorpHub!\nYour login details are:\nPIN: $pin\nPassword: $pass';
    final waUri = Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(msg)}');
    if (await canLaunchUrl(waUri)) {
      await launchUrl(waUri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;

    return Scaffold(
      appBar: AppBar(title: Text(s.t('Admin Control Panel', 'لوحة تحكم الإدارة'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(s.t('Field Visibility for Non-Logged Users:', 'إعدادات إخفاء وإظهار الأعمدة لغير المسجلين:'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
            title: Text(s.t('Show Operation / Factory Addresses', 'إظهار عناوين التشغيل والمصانع')),
            value: widget.privacy['public_show_operation_addresses'] ?? false,
            onChanged: (v) => _toggleSetting('public_show_operation_addresses', v),
          ),
          const Divider(height: 32),
          Text(s.t('Pending Access Requests (${_requests.length})', 'طلبات الانضمام المعلقة (${_requests.length})'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
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
                      onPressed: () => _approveRequest(r),
                    ),
                  ),
                )),
        ],
      ),
    );
  }
}
