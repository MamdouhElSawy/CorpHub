import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart';

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
  runApp(const CorpHubApp());
}

// ----------------- إدارة اللغات والمظهر وهيكل EGL -----------------
class AppState extends ChangeNotifier {
  static final AppState instance = AppState._();
  AppState._();

  bool isArabic = false; // الأساسي إنجليزي
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

  bool get _canEdit {
    if (_currentUser == null) return false;
    final r = _currentUser!['role'];
    return r == 'admin' || r == 'editor';
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
                  leading: const Icon(Icons.logout, color: Colors.redAccent),
                  title: Text('${s.t("Logout", "خروج")} (${_currentUser!["username"] ?? ""}) - ${_currentUser!["role"]?.toString().toUpperCase()}'),
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

  void _openAddEditCompanyDialog([Map<String, dynamic>? company]) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (_) => AddEditCompanyDialog(company: company),
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
                                  isLoggedIn: isLoggedIn,
                                  canEdit: _canEdit,
                                  privacy: _privacy,
                                  onEdit: () => _openAddEditCompanyDialog(comp),
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

// ----------------- كارت الشركة مع زر التعديل للمصرح لهم -----------------
class CompanyCard extends StatelessWidget {
  final Map<String, dynamic> company;
  final bool isLoggedIn;
  final bool canEdit;
  final Map<String, bool> privacy;
  final VoidCallback onEdit;
  final VoidCallback onShare;

  const CompanyCard({
    super.key,
    required this.company,
    required this.isLoggedIn,
    required this.canEdit,
    required this.privacy,
    required this.onEdit,
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
        title: Row(
          children: [
            Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
            if (canEdit)
              IconButton(
                icon: const Icon(Icons.edit, size: 20, color: Color(0xFF008DDA)),
                tooltip: s.t('Edit Company', 'تعديل بيانات الشركة'),
                onPressed: onEdit,
              ),
          ],
        ),
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

// ----------------- نافذة إضافة وتعديل شركة يدوياً (لـ Editor و Admin) -----------------
class AddEditCompanyDialog extends StatefulWidget {
  final Map<String, dynamic>? company;
  const AddEditCompanyDialog({super.key, this.company});

  @override
  State<AddEditCompanyDialog> createState() => _AddEditCompanyDialogState();
}

class _AddEditCompanyDialogState extends State<AddEditCompanyDialog> {
  final _nameEn = TextEditingController();
  final _nameAr = TextEditingController();
  final _taxCardUrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.company != null) {
      _nameEn.text = widget.company!['name_en'] ?? '';
      _nameAr.text = widget.company!['name_ar'] ?? '';
      _taxCardUrl.text = widget.company!['tax_card_url'] ?? '';
    }
  }

  void _save() async {
    final s = AppState.instance;
    if (_nameEn.text.trim().isEmpty && _nameAr.text.trim().isEmpty) return;

    setState(() => _saving = true);
    final data = {
      'name_en': _nameEn.text.trim(),
      'name_ar': _nameAr.text.trim(),
      'tax_card_url': _taxCardUrl.text.trim().isEmpty ? null : _taxCardUrl.text.trim(),
    };

    try {
      if (widget.company == null) {
        await Supabase.instance.client.from('companies').insert(data);
      } else {
        await Supabase.instance.client.from('companies').update(data).eq('id', widget.company!['id']);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final isNew = widget.company == null;

    return AlertDialog(
      title: Text(isNew ? s.t('Add New Company', 'إضافة شركة جديدة') : s.t('Edit Company', 'تعديل بيانات الشركة')),
      content: SizedBox(
        width: 450,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameEn,
              decoration: InputDecoration(hintText: s.t('Company Name (English)', 'اسم الشركة بالإنجليزي')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameAr,
              decoration: InputDecoration(hintText: s.t('Company Name (Arabic)', 'اسم الشركة بالعربي')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _taxCardUrl,
              decoration: InputDecoration(hintText: s.t('Tax Card Image URL', 'رابط صورة البطاقة الضريبية')),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('Cancel', 'إلغاء'))),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving ? const CircularProgressIndicator() : Text(s.t('Save', 'حفظ')),
        ),
      ],
    );
  }
}

// ----------------- نافذة الدخول مع دعم Enter -----------------
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
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
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
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
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

// ----------------- لوحة تحكم الأدمن الشاملة (تبويبات: إكسيل - يوزرات - خصوصية - طلبات) -----------------
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

  // --- دوال إدارة الإكسيل ---
  void _downloadTemplate() {
    var excel = Excel.createExcel();
    Sheet sheet = excel['CompaniesTemplate'];
    excel.delete('Sheet1');

    sheet.appendRow([
      TextCellValue('Company_Name_EN'),
      TextCellValue('Company_Name_AR'),
      TextCellValue('Address_Type'), // mailing or operation
      TextCellValue('Address_EN'),
      TextCellValue('Address_AR'),
      TextCellValue('Contact_Name_EN'),
      TextCellValue('Contact_Name_AR'),
      TextCellValue('Contact_Role'),
      TextCellValue('Contact_Phone'),
      TextCellValue('Tax_Card_URL'),
    ]);

    // مثال توضيحي
    sheet.appendRow([
      TextCellValue('EGL Logistics'),
      TextCellValue('المصرية للخدمات اللوجستية'),
      TextCellValue('operation'),
      TextCellValue('Alexandria Port, Gate 27'),
      TextCellValue('ميناء الإسكندرية، باب 27'),
      TextCellValue('Ahmed Hassan'),
      TextCellValue('أحمد حسن'),
      TextCellValue('Operations Director'),
      TextCellValue('+201200000000'),
      TextCellValue('https://...'),
    ]);

    final bytes = excel.encode();
    if (bytes != null) {
      _triggerDownloadWeb(bytes, 'corphub_template.xlsx');
    }
  }

  void _exportCurrentData() {
    var excel = Excel.createExcel();
    Sheet sheet = excel['CorpHub_Export'];
    excel.delete('Sheet1');

    sheet.appendRow([
      TextCellValue('Company_Name_EN'),
      TextCellValue('Company_Name_AR'),
      TextCellValue('Address_Type'),
      TextCellValue('Address_EN'),
      TextCellValue('Address_AR'),
      TextCellValue('Contact_Name_EN'),
      TextCellValue('Contact_Name_AR'),
      TextCellValue('Contact_Role'),
      TextCellValue('Contact_Phone'),
      TextCellValue('Tax_Card_URL'),
    ]);

    for (var c in widget.companies) {
      final addrs = (c['company_addresses'] as List? ?? []);
      final contacts = (c['company_contacts'] as List? ?? []);
      final maxRows = max(addrs.length, contacts.length);

      if (maxRows == 0) {
        sheet.appendRow([
          TextCellValue(c['name_en'] ?? ''),
          TextCellValue(c['name_ar'] ?? ''),
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

      for (var table in excel.tables.keys) {
        final rows = excel.tables[table]!.rows;
        if (rows.length <= 1) continue;

        for (int i = 1; i < rows.length; i++) {
          final row = rows[i];
          if (row.isEmpty) continue;

          final nameEn = row.length > 0 ? row[0]?.value?.toString().trim() ?? '' : '';
          final nameAr = row.length > 1 ? row[1]?.value?.toString().trim() ?? '' : '';
          final addrType = row.length > 2 ? row[2]?.value?.toString().trim() ?? 'mailing' : 'mailing';
          final addrEn = row.length > 3 ? row[3]?.value?.toString().trim() : null;
          final addrAr = row.length > 4 ? row[4]?.value?.toString().trim() : null;
          final contNameEn = row.length > 5 ? row[5]?.value?.toString().trim() : null;
          final contNameAr = row.length > 6 ? row[6]?.value?.toString().trim() : null;
          final contRole = row.length > 7 ? row[7]?.value?.toString().trim() : null;
          final contPhone = row.length > 8 ? row[8]?.value?.toString().trim() : null;
          final taxCardUrl = row.length > 9 ? row[9]?.value?.toString().trim() : null;

          if (nameEn.isEmpty && nameAr.isEmpty) continue;

          // إضافة أو جلب الشركة
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
              'tax_card_url': taxCardUrl,
            }).select().single();
            compId = ins['id'];
          } else {
            compId = comp['id'];
            if (taxCardUrl != null && taxCardUrl.isNotEmpty) {
              await Supabase.instance.client.from('companies').update({'tax_card_url': taxCardUrl}).eq('id', compId);
            }
          }

          // إضافة العنوان
          if ((addrEn != null && addrEn.isNotEmpty) || (addrAr != null && addrAr.isNotEmpty)) {
            await Supabase.instance.client.from('company_addresses').insert({
              'company_id': compId,
              'type': addrType == 'operation' ? 'operation' : 'mailing',
              'address_en': addrEn,
              'address_ar': addrAr,
            });
          }

          // إضافة جهة الاتصال
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
      }

      widget.onUpdate();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('Excel data processed successfully!', 'تمت معالجة ملف الإكسيل بنجاح!'))));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      setState(() => _busy = false);
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('All company data has been wiped.', 'تم تفريغ كافة البيانات.'))));
    }
  }

  // --- دوال إدارة المستخدمين ---
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
                // 1. تبويب الإكسيل
                ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(s.t('Excel Management & Bulk Import', 'مركز إدارة وتحميل ملفات الإكسيل'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    const SizedBox(height: 16),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.download, color: Colors.blueAccent),
                        title: Text(s.t('Download Excel Template (template.xlsx)', 'تحميل القالب الفارغ (template.xlsx)')),
                        subtitle: Text(s.t('Download template with predefined columns', 'ملف فارغ جاهز بالأعمدة المطلوبة لملء بيانات الشركات')),
                        trailing: ElevatedButton(onPressed: _downloadTemplate, child: Text(s.t('Download', 'تحميل'))),
                      ),
                    ),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.file_download, color: Colors.teal),
                        title: Text(s.t('Export Current Data to Excel', 'تنزيل الداتا الحالية في إكسيل للتعديل')),
                        subtitle: Text(s.t('Download all stored companies and contacts to edit them on your PC', 'تنزيل كامل الشركات والعناوين لتعديلها ثم إعادة رفعها')),
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

                // 2. تبويب إدارة المستخدمين
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

                // 3. تبويب الخصوصية
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

                // 4. تبويب طلبات الانضمام
                ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(s.t('Pending Access Requests (${_requests.length})', 'طلبات الانضمام المعلقة (${_requests.length})'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
