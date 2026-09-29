import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const CorpHubApp());
}

// ----------------- إدارة اللغات والمظهر -----------------
class AppState extends ChangeNotifier {
  static final AppState instance = AppState._();
  AppState._();

  bool isArabic = false;
  ThemeMode themeMode = ThemeMode.dark;

  void toggleLanguage() {
    isArabic = !isArabic;
    notifyListeners();
  }

  void toggleTheme(bool dark) {
    themeMode = dark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }

  String t(String ar, String en) => isArabic ? ar : en;
}

class CorpHubApp extends StatelessWidget {
  const CorpHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppState.instance,
      builder: (context, _) {
        final state = AppState.instance;
        return MaterialApp(
          title: state.isArabic ? 'دليل الشركات' : 'CorpHub',
          debugShowCheckedModeBanner: false,
          themeMode: state.themeMode,
          locale: Locale(state.isArabic ? 'ar' : 'en'),
          theme: ThemeData(
            brightness: Brightness.light,
            scaffoldBackgroundColor: const Color(0xFFF8FAFC),
            primaryColor: const Color(0xFF0284C7),
            cardColor: Colors.white,
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF0284C7),
              surface: Colors.white,
            ),
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF0F172A),
            primaryColor: const Color(0xFF38BDF8),
            cardColor: const Color(0xFF1E293B),
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF38BDF8),
              surface: Color(0xFF1E293B),
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
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.language),
              title: Text(s.t('اللغة: العربية', 'Language: English')),
              trailing: Switch(
                value: s.isArabic,
                onChanged: (_) {
                  s.toggleLanguage();
                  Navigator.pop(ctx);
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.dark_mode_outlined),
              title: Text(s.t('الوضع الليلي (Dark Mode)', 'Dark Theme')),
              trailing: Switch(
                value: s.themeMode == ThemeMode.dark,
                onChanged: (val) {
                  s.toggleTheme(val);
                  Navigator.pop(ctx);
                },
              ),
            ),
            const Divider(),
            if (_currentUser == null)
              ListTile(
                leading: const Icon(Icons.login),
                title: Text(s.t('تسجيل الدخول', 'Login')),
                onTap: () {
                  Navigator.pop(ctx);
                  _openLoginDialog();
                },
              )
            else ...[
              if (_currentUser!['role'] == 'admin')
                ListTile(
                  leading: const Icon(Icons.admin_panel_settings, color: Colors.blueAccent),
                  title: Text(s.t('لوحة تحكم الإدارة', 'Admin Panel')),
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
                title: Text('${s.t("خروج", "Logout")} (${_currentUser!["username"] ?? ""})'),
                onTap: () {
                  setState(() => _currentUser = null);
                  Navigator.pop(ctx);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _openLoginDialog() async {
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
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
        SnackBar(content: Text(s.t('لا توجد صورة مسجلة', 'No image registered'))),
      );
      return;
    }
    final msg = '${s.t("البطاقة الضريبية لشركة:", "Tax Card for:")} $companyName\n$url';
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
        title: Text(s.isArabic ? 'دليل الشركات' : 'CorpHub', style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: s.t('الإعدادات', 'Settings'),
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
                  const Icon(Icons.lock_outline, size: 64, color: Colors.orangeAccent),
                  const SizedBox(height: 16),
                  Text(s.t('التصفح مغلق لغير المسجلين', 'Browsing restricted to members'), style: const TextStyle(fontSize: 18)),
                  const SizedBox(height: 12),
                  ElevatedButton(onPressed: _openLoginDialog, child: Text(s.t('تسجيل الدخول', 'Login'))),
                ],
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: s.t('ابحث باسم الشركة...', 'Search company name...'),
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                    ),
                    onChanged: (val) => setState(() => _searchQuery = val),
                  ),
                ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : filtered.isEmpty
                          ? Center(child: Text(s.t('لا توجد بيانات مطابقة', 'No companies found')))
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
                                    s.isArabic ? (comp['name_ar'] ?? '') : (comp['name_en'] ?? ''),
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

// ----------------- كارت الشركة -----------------
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
    final name = s.isArabic ? (company['name_ar'] ?? '') : (company['name_en'] ?? '');

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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).primaryColor.withAlpha(30),
          child: Icon(Icons.business, color: Theme.of(context).primaryColor),
        ),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
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
                        label: Text(s.t('واتساب البطاقة', 'Share Tax Card')),
                        onPressed: onShare,
                      ),
                      const SizedBox(width: 8),
                    ],
                    OutlinedButton.icon(
                      icon: const Icon(Icons.print, size: 16),
                      label: Text(s.t('طباعة مخصصة', 'Selective Print')),
                      onPressed: () => showDialog(
                        context: context,
                        builder: (_) => SelectivePrintDialog(company: company),
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                if (addresses.isNotEmpty) ...[
                  Text(s.t('📍 العناوين:', '📍 Addresses:'), style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).primaryColor)),
                  const SizedBox(height: 6),
                  ...addresses.map((a) {
                    final isMail = a['type'] == 'mailing';
                    final addrText = s.isArabic ? (a['address_ar'] ?? '') : (a['address_en'] ?? '');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text('• [${isMail ? s.t("مراسلة", "Mailing") : s.t("تشغيل", "Operation")}]: $addrText'),
                    );
                  }),
                  const SizedBox(height: 12),
                ],
                if (contacts.isNotEmpty) ...[
                  Text(s.t('👤 جهات الاتصال والأفراد:', '👤 Contacts:'), style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).primaryColor)),
                  const SizedBox(height: 6),
                  ...contacts.map((c) {
                    final cName = s.isArabic ? (c['name_ar'] ?? '') : (c['name_en'] ?? '');
                    final cRole = s.isArabic ? (c['role_ar'] ?? '') : (c['role_en'] ?? '');
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
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('تم النسخ', 'Copied'))));
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

// ----------------- نافذة الدخول النظيفة -----------------
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
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final pin = _pinController.text.trim();
      final pass = _passController.text.trim();

      final res = await Supabase.instance.client
          .from('app_users')
          .select()
          .eq('pin_code', pin)
          .eq('is_active', true)
          .maybeSingle();

      if (res == null) {
        setState(() => _error = s.t('كود الدخول غير صحيح', 'Invalid PIN code'));
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
          content: Text(s.t('تم إرسال طلبك للإدارة، سيتم إرسال بيانات الدخول عبر الواتساب فور الموافقة.', 'Request sent. Credentials will be sent via WhatsApp once approved.')),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _showRequestForm ? s.t('طلب انضمام جديد', 'Request Access') : s.t('تسجيل الدخول', 'Login'),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            if (!_showRequestForm) ...[
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, letterSpacing: 6, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: s.t('كود الدخول (6 أرقام)', '6-Digit PIN'),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passController,
                obscureText: true,
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  hintText: s.t('كلمة المرور', 'Password'),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 16),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
                ),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _loading ? null : _login,
                  child: _loading ? const CircularProgressIndicator(color: Colors.black) : Text(s.t('تسجيل الدخول', 'Login')),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => setState(() => _showRequestForm = true),
                child: Text(s.t('طلب حساب مستخدم جديد', 'Request a new account')),
              ),
            ] else ...[
              TextField(
                controller: _nameReqController,
                decoration: InputDecoration(
                  hintText: s.t('الاسم بالكامل', 'Full Name'),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phoneReqController,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  hintText: s.t('رقم الهاتف (واتساب)', 'WhatsApp Phone Number'),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _submitRequest,
                  child: Text(s.t('إرسال الطلب للإدارة', 'Submit Request')),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _showRequestForm = false),
                child: Text(s.t('رجوع لتسجيل الدخول', 'Back to login')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ----------------- الطباعة الانتقائية مع إخفاء الأقسام الفارغة -----------------
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
      SnackBar(content: Text(AppState.instance.t('تم إعداد التقرير المحدد للطباعة', 'Report ready for print'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final addrs = widget.company['company_addresses'] as List? ?? [];
    final contacts = widget.company['company_contacts'] as List? ?? [];

    return AlertDialog(
      title: Text(s.t('طباعة انتقائية', 'Selective Print')),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CheckboxListTile(
                title: Text(s.t('اسم الشركة الرئيسي', 'Company Name')),
                value: _incName,
                onChanged: (v) => setState(() => _incName = v ?? true),
              ),
              CheckboxListTile(
                title: Text(s.t('صورة البطاقة الضريبية', 'Tax Card Image')),
                value: _incTaxCard,
                onChanged: (v) => setState(() => _incTaxCard = v ?? false),
              ),
              const Divider(),
              if (addrs.isNotEmpty) ...[
                Text(s.t('اختر العناوين المطلوب طباعتها:', 'Select addresses to print:'), style: const TextStyle(fontWeight: FontWeight.bold)),
                ...addrs.map((a) {
                  final text = s.isArabic ? (a['address_ar'] ?? '') : (a['address_en'] ?? '');
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
                Text(s.t('اختر الأفراد المطلوب طباعتهم:', 'Select contacts to print:'), style: const TextStyle(fontWeight: FontWeight.bold)),
                ...contacts.map((c) {
                  final name = s.isArabic ? (c['name_ar'] ?? '') : (c['name_en'] ?? '');
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
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('إلغاء', 'Cancel'))),
        ElevatedButton(onPressed: _executePrint, child: Text(s.t('طباعة', 'Print'))),
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
    final msg = 'مرحباً بك في دليل الشركات (CorpHub)!\nبيانات دخولك هي:\nPIN: $pin\nPassword: $pass';
    final waUri = Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(msg)}');
    if (await canLaunchUrl(waUri)) {
      await launchUrl(waUri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;

    return Scaffold(
      appBar: AppBar(title: Text(s.t('لوحة تحكم الإدارة', 'Admin Panel'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(s.t('إعدادات إخفاء وإظهار الأعمدة لغير المسجلين:', 'Column Privacy for Non-Logged Users:'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          SwitchListTile(
            title: Text(s.t('السماح بالتصفح العام (فتح/قفل)', 'Allow Public Browsing')),
            value: widget.privacy['allow_public_read'] ?? true,
            onChanged: (v) => _toggleSetting('allow_public_read', v),
          ),
          SwitchListTile(
            title: Text(s.t('إظهار صورة البطاقة الضريبية', 'Show Tax Card')),
            value: widget.privacy['public_show_tax_card'] ?? false,
            onChanged: (v) => _toggleSetting('public_show_tax_card', v),
          ),
          SwitchListTile(
            title: Text(s.t('إظهار أرقام الهواتف', 'Show Phone Numbers')),
            value: widget.privacy['public_show_phones'] ?? false,
            onChanged: (v) => _toggleSetting('public_show_phones', v),
          ),
          SwitchListTile(
            title: Text(s.t('إظهار عناوين التشغيل والمصانع', 'Show Operation Addresses')),
            value: widget.privacy['public_show_operation_addresses'] ?? false,
            onChanged: (v) => _toggleSetting('public_show_operation_addresses', v),
          ),
          const Divider(height: 32),
          Text(s.t('طلبات الانضمام المعلقة (${_requests.length})', 'Pending Access Requests (${_requests.length})'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          if (_requests.isEmpty)
            Text(s.t('لا توجد طلبات معلقة حالياً', 'No pending requests'))
          else
            ..._requests.map((r) => Card(
                  child: ListTile(
                    title: Text(r['full_name']),
                    subtitle: Text(r['phone']),
                    trailing: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF25D366), foregroundColor: Colors.white),
                      icon: const Icon(Icons.check, size: 16),
                      label: Text(s.t('قبول وإرسال واتساب', 'Approve & WhatsApp')),
                      onPressed: () => _approveRequest(r),
                    ),
                  ),
                )),
        ],
      ),
    );
  }
}
