import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' as ex;

// ----------------- App State Management -----------------
class AppState extends ChangeNotifier {
  static final AppState instance = AppState._internal();
  AppState._internal();

  bool isArabic = true;
  bool isDarkMode = false;

  void toggleLanguage() {
    isArabic = !isArabic;
    notifyListeners();
  }

  void toggleTheme() {
    isDarkMode = !isDarkMode;
    notifyListeners();
  }

  String t(String en, String ar) => isArabic ? ar : en;
}

// ----------------- Main Entry Point -----------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://vhfxigewirlnqrrrjbjn.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZoZnhpZ2V3aXJsbnFycnJqYmpuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Mjc2MzIxNjUsImV4cCI6MjA0MzIwODE2NX0.9X2Y63mZp5P45rA9y6bE2M0K4y9W8V0-X8J8b_p9R40',
  );

  runApp(const CorpHubApp());
}

class CorpHubApp extends StatefulWidget {
  const CorpHubApp({super.key});

  @override
  State<CorpHubApp> createState() => _CorpHubAppState();
}

class _CorpHubAppState extends State<CorpHubApp> {
  @override
  void initState() {
    super.initState();
    AppState.instance.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    return MaterialApp(
      title: 'CorpHub',
      debugShowCheckedModeBanner: false,
      themeMode: s.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF008DDA),
          primary: const Color(0xFF008DDA),
          secondary: const Color(0xFF41B06E),
          surface: Colors.white,
        ),
        fontFamily: 'Segoe UI',
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF008DDA),
          brightness: Brightness.dark,
          primary: const Color(0xFF008DDA),
          secondary: const Color(0xFF41B06E),
          surface: const Color(0xFF1E293B),
        ),
        fontFamily: 'Segoe UI',
      ),
      home: const MainScreen(),
    );
  }
}

// ----------------- Main Screen -----------------
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _supabase = Supabase.instance.client;
  List<Map<String, dynamic>> _companies = [];
  bool _isLoading = true;
  String _searchQuery = '';
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _checkAdminStatus();
    _fetchCompanies();
  }

  void _checkAdminStatus() {
    final session = _supabase.auth.currentSession;
    setState(() {
      _isAdmin = session != null;
    });
  }

  Future<void> _fetchCompanies() async {
    setState(() => _isLoading = true);
    try {
      final response = await _supabase
          .from('companies')
          .select('*, company_addresses(*), company_contacts(*)')
          .order('name_ar', ascending: true);

      setState(() {
        _companies = List<Map<String, dynamic>>.from(response);
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  List<Map<String, dynamic>> get _filteredCompanies {
    if (_searchQuery.isEmpty) return _companies;
    final q = _searchQuery.toLowerCase();
    return _companies.where((c) {
      final nameAr = (c['name_ar'] ?? '').toString().toLowerCase();
      final nameEn = (c['name_en'] ?? '').toString().toLowerCase();
      return nameAr.contains(q) || nameEn.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final isMobile = MediaQuery.of(context).size.width < 700;

    return Scaffold(
      appBar: AppBar(
        elevation: 1,
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset(
                'assets/images/egl_logo.png',
                height: isMobile ? 32 : 40,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFF008DDA), borderRadius: BorderRadius.circular(4)),
                  child: const Text('EGL', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.white)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'CorpHub',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: isMobile ? 18 : 22,
                color: const Color(0xFF0B192C),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(s.isDarkMode ? Icons.light_mode : Icons.dark_mode),
            onPressed: s.toggleTheme,
            tooltip: s.t('Toggle Theme', 'تغيير المظهر'),
          ),
          IconButton(
            icon: const Icon(Icons.language),
            onPressed: s.toggleLanguage,
            tooltip: s.t('Change Language', 'تغيير اللغة'),
          ),
          if (!_isAdmin)
            IconButton(
              icon: const Icon(Icons.admin_panel_settings),
              onPressed: _showLoginDialog,
              tooltip: s.t('Admin Login', 'دخول المسؤول'),
            )
          else
            IconButton(
              icon: const Icon(Icons.logout, color: Colors.red),
              onPressed: () async {
                await _supabase.auth.signOut();
                _checkAdminStatus();
              },
              tooltip: s.t('Logout', 'تسجيل الخروج'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16.0),
            color: Theme.of(context).colorScheme.surface,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: s.t('Search company...', 'بحث عن شركة...'),
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                ),
                if (_isAdmin) ...[
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    onPressed: () => _showCompanyFormDialog(),
                    icon: const Icon(Icons.add),
                    label: Text(s.t('Add Company', 'إضافة شركة')),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF008DDA),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredCompanies.isEmpty
                    ? Center(child: Text(s.t('No companies found', 'لا توجد شركات')))
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _filteredCompanies.length,
                        itemBuilder: (context, index) {
                          final company = _filteredCompanies[index];
                          return CompanyCard(
                            company: company,
                            isAdmin: _isAdmin,
                            onRefresh: _fetchCompanies,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  void _showLoginDialog() {
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    final s = AppState.instance;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.t('Admin Login', 'دخول المسؤول')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: emailController, decoration: InputDecoration(labelText: s.t('Email', 'البريد الإلكتروني'))),
            TextField(controller: passwordController, obscureText: true, decoration: InputDecoration(labelText: s.t('Password', 'كلمة المرور'))),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('Cancel', 'إلغاء'))),
          ElevatedButton(
            onPressed: () async {
              try {
                await _supabase.auth.signInWithPassword(
                  email: emailController.text.trim(),
                  password: passwordController.text.trim(),
                );
                _checkAdminStatus();
                Navigator.pop(context);
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('Login failed', 'فشل تسجيل الدخول'))));
              }
            },
            child: Text(s.t('Login', 'دخول')),
          ),
        ],
      ),
    );
  }

  void _showCompanyFormDialog([Map<String, dynamic>? company]) {
    showDialog(
      context: context,
      builder: (context) => CompanyFormDialog(company: company, onSave: _fetchCompanies),
    );
  }
}

// ----------------- Company Card Component -----------------
class CompanyCard extends StatelessWidget {
  final Map<String, dynamic> company;
  final bool isAdmin;
  final VoidCallback onRefresh;

  const CompanyCard({
    super.key,
    required this.company,
    required this.isAdmin,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;
    final addresses = company['company_addresses'] as List? ?? [];
    final contacts = company['company_contacts'] as List? ?? [];
    final compName = s.isArabic ? (company['name_ar'] ?? company['name_en'] ?? '') : (company['name_en'] ?? company['name_ar'] ?? '');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ExpansionTile(
        title: Text(compName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        subtitle: Text('${addresses.length} ${s.t("Addresses", "عناوين")} | ${contacts.length} ${s.t("Contacts", "جهات اتصال")}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.print, color: Color(0xFF008DDA)),
              onPressed: () => _showSelectivePrintDialog(context),
            ),
            if (isAdmin) ...[
              IconButton(
                icon: const Icon(Icons.edit, color: Colors.orange),
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => CompanyFormDialog(company: company, onSave: onRefresh),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () => _confirmDelete(context),
              ),
            ],
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (addresses.isNotEmpty) ...[
                  Text(s.t('Addresses:', 'العناوين:'), style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  ...addresses.map((a) => Padding(
                    padding: const EdgeInsets.only(bottom: 4.0),
                    child: Text('• ${a['type'] == 'mailing' ? s.t('[Mailing]', '[مراسلة]') : s.t('[Operation]', '[تشغيل]')} ${s.isArabic ? (a['address_ar'] ?? a['address_en']) : (a['address_en'] ?? a['address_ar'])}'),
                  )),
                  const Divider(),
                ],
                if (contacts.isNotEmpty) ...[
                  Text(s.t('Contacts:', 'جهات الاتصال:'), style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  ...contacts.map((c) => Padding(
                    padding: const EdgeInsets.only(bottom: 4.0),
                    child: Text('• ${s.isArabic ? (c['name_ar'] ?? c['name_en']) : (c['name_en'] ?? c['name_ar'])} (${s.isArabic ? (c['role_ar'] ?? c['role_en']) : (c['role_en'] ?? c['role_ar'])}) - ${c['phone'] ?? ''}'),
                  )),
                ],
                if (company['tax_card_url'] != null) ...[
                  const Divider(),
                  Row(
                    children: [
                      const Icon(Icons.badge, color: Color(0xFF008DDA)),
                      const SizedBox(width: 8),
                      Text(s.t('Tax Card Available', 'البطاقة الضريبية متاحة')),
                      const Spacer(),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.share, size: 16),
                        label: Text(s.t('WhatsApp', 'واتساب')),
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF25D366), foregroundColor: Colors.white),
                        onPressed: () {
                          final url = "https://wa.me/?text=${Uri.encodeComponent('${s.t("Tax Card for", "البطاقة الضريبية لـ")} $compName: ${company['tax_card_url']}')}";
                          html.window.open(url, '_blank');
                        },
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showSelectivePrintDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => SelectivePrintDialog(company: company),
    );
  }

  void _confirmDelete(BuildContext context) {
    final s = AppState.instance;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(s.t('Delete Company', 'حذف الشركة')),
        content: Text(s.t('Are you sure you want to delete this record?', 'هل أنت تأكد من رغبتك في حذف هذا السجل؟')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('Cancel', 'إلغاء'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () async {
              await Supabase.instance.client.from('companies').delete().eq('id', company['id']);
              Navigator.pop(context);
              onRefresh();
            },
            child: Text(s.t('Delete', 'حذف')),
          ),
        ],
      ),
    );
  }
}

// ----------------- Selective Print Dialog -----------------
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
        <title>CorpHub - ${s.t('Print Record', 'طباعة تقرير')}</title>
        <style>
          body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; padding: 30px; color: #111; }
          .header { text-align: center; border-bottom: 2px solid #008DDA; padding-bottom: 12px; margin-bottom: 20px; }
          .header h1 { margin: 0; font-size: 24px; color: #0B192C; }
          .section { margin-bottom: 20px; }
          .section-title { font-weight: bold; font-size: 16px; color: #008DDA; border-bottom: 1px solid #ccc; padding-bottom: 4px; margin-bottom: 8px; }
          .item { font-size: 14px; margin-bottom: 6px; }
          
          /* صفحة مستقلة للبطاقة الضريبية بوضوح تام مع محاذاة في المنتصف */
          .tax-card-page { page-break-before: always; text-align: center; padding-top: 20px; }
          .tax-card-container {
            width: 100%;
            display: flex;
            justify-content: center;
            align-items: center;
            margin-top: 15px;
            padding: 10px;
          }
          .tax-card-img {
            max-width: 100%;
            max-height: 80vh;
            width: auto;
            height: auto;
            object-fit: contain;
            border: 1px solid #ddd;
            border-radius: 6px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
          }
          .pdf-frame {
            width: 100%;
            height: 75vh;
            border: 1px solid #ccc;
            border-radius: 8px;
            margin-top: 15px;
          }
          @media print {
            body { padding: 0; }
            .tax-card-page { page-break-before: always; }
          }
        </style>
      </head>
      <body>
        <div class="header">
          ${_incName ? "<h1>$compName</h1>" : ""}
          <p style="font-size: 12px; color: #666;">CorpHub Corporate Directory</p>
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
      if (!url.toLowerCase().contains('.pdf')) {
        contentHtml += '''
          <div class="tax-card-page">
            <div class="section-title">${s.t("Tax Card Document:", "مستند البطاقة الضريبية:")}</div>
            <div class="tax-card-container">
              <img class="tax-card-img" src="$url" />
            </div>
          </div>
        ''';
      } else {
        contentHtml += '''
          <div class="tax-card-page">
            <div class="section-title">${s.t("Tax Card (PDF Document):", "مستند البطاقة الضريبية (PDF):")}</div>
            <iframe class="pdf-frame" src="$url"></iframe>
          </div>
        ''';
      }
    }

    contentHtml += '''
        <script>
          window.onload = function() {
            window.print();
          };
        </script>
      </body>
      </html>
    ''';

    final blob = html.Blob([contentHtml], 'text/html');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
    Navigator.pop(context);
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
                title: Text(s.t('Tax Card / PDF (Dedicated Page)', 'البطاقة الضريبية / مستند مستقل بالطباعة')),
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

// ----------------- Company Form Dialog -----------------
class CompanyFormDialog extends StatefulWidget {
  final Map<String, dynamic>? company;
  final VoidCallback onSave;

  const CompanyFormDialog({super.key, this.company, required this.onSave});

  @override
  State<CompanyFormDialog> createState() => _CompanyFormDialogState();
}

class _CompanyFormDialogState extends State<CompanyFormDialog> {
  final _nameArController = TextEditingController();
  final _nameEnController = TextEditingController();
  String? _taxCardUrl;
  bool _isUploading = false;

  final List<Map<String, String>> _addresses = [];
  final List<Map<String, String>> _contacts = [];

  @override
  void initState() {
    super.initState();
    if (widget.company != null) {
      _nameArController.text = widget.company!['name_ar'] ?? '';
      _nameEnController.text = widget.company!['name_en'] ?? '';
      _taxCardUrl = widget.company!['tax_card_url'];

      final addrs = widget.company!['company_addresses'] as List? ?? [];
      for (var a in addrs) {
        _addresses.add({
          'type': a['type'] ?? 'mailing',
          'address_ar': a['address_ar'] ?? '',
          'address_en': a['address_en'] ?? '',
        });
      }

      final contacts = widget.company!['company_contacts'] as List? ?? [];
      for (var c in contacts) {
        _contacts.add({
          'name_ar': c['name_ar'] ?? '',
          'name_en': c['name_en'] ?? '',
          'role_ar': c['role_ar'] ?? '',
          'role_en': c['role_en'] ?? '',
          'phone': c['phone'] ?? '',
        });
      }
    }
  }

  // ضغط تلقائي وتحجيم قبل الرفع للسرعة
  Future<Uint8List> _compressImage(Uint8List bytes) async {
    final completer = Completer<Uint8List>();
    final blob = html.Blob([bytes]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    final img = html.ImageElement();

    img.src = url;
    img.onLoad.listen((_) {
      final canvas = html.CanvasElement();
      int width = img.width ?? 800;
      int height = img.height ?? 600;

      const maxDim = 1200;
      if (width > maxDim || height > maxDim) {
        if (width > height) {
          height = (height * maxDim / width).round();
          width = maxDim;
        } else {
          width = (width * maxDim / height).round();
          height = maxDim;
        }
      }

      canvas.width = width;
      canvas.height = height;
      final ctx = canvas.context2D;
      ctx.drawImageScaled(img, 0, 0, width, height);

      final dataUrl = canvas.toDataUrl('image/jpeg', 0.75);
      html.Url.revokeObjectUrl(url);

      final base64Str = dataUrl.split(',').last;
      completer.complete(base64Decode(base64Str));
    });

    return completer.future;
  }

  Future<void> _pickAndUploadTaxCard() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'png', 'pdf'],
      withData: true,
    );

    if (result != null && result.files.single.bytes != null) {
      setState(() => _isUploading = true);
      try {
        final file = result.files.single;
        final isPdf = file.extension?.toLowerCase() == 'pdf';
        Uint8List uploadBytes = file.bytes!;

        if (!isPdf) {
          uploadBytes = await _compressImage(uploadBytes);
        }

        final fileName = '${DateTime.now().millisecondsSinceEpoch}_${file.name}';
        final storage = Supabase.instance.client.storage.from('tax_cards');

        await storage.uploadBinary(
          fileName,
          uploadBytes,
          fileOptions: FileOptions(contentType: isPdf ? 'application/pdf' : 'image/jpeg'),
        );

        final publicUrl = storage.getPublicUrl(fileName);
        setState(() {
          _taxCardUrl = publicUrl;
          _isUploading = false;
        });
      } catch (e) {
        setState(() => _isUploading = false);
      }
    }
  }

  Future<void> _saveCompany() async {
    final supabase = Supabase.instance.client;
    final compData = {
      'name_ar': _nameArController.text.trim(),
      'name_en': _nameEnController.text.trim(),
      'tax_card_url': _taxCardUrl,
    };

    String companyId;
    if (widget.company == null) {
      final res = await supabase.from('companies').insert(compData).select().single();
      companyId = res['id'].toString();
    } else {
      companyId = widget.company!['id'].toString();
      await supabase.from('companies').update(compData).eq('id', companyId);
      await supabase.from('company_addresses').delete().eq('company_id', companyId);
      await supabase.from('company_contacts').delete().eq('company_id', companyId);
    }

    for (var a in _addresses) {
      await supabase.from('company_addresses').insert({
        'company_id': companyId,
        'type': a['type'],
        'address_ar': a['address_ar'],
        'address_en': a['address_en'],
      });
    }

    for (var c in _contacts) {
      await supabase.from('company_contacts').insert({
        'company_id': companyId,
        'name_ar': c['name_ar'],
        'name_en': c['name_en'],
        'role_ar': c['role_ar'],
        'role_en': c['role_en'],
        'phone': c['phone'],
      });
    }

    widget.onSave();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.instance;

    return AlertDialog(
      title: Text(widget.company == null ? s.t('Add Company', 'إضافة شركة') : s.t('Edit Company', 'تعديل شركة')),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(controller: _nameArController, decoration: InputDecoration(labelText: s.t('Arabic Name', 'الاسم بالعربية'))),
              const SizedBox(height: 8),
              TextField(controller: _nameEnController, decoration: InputDecoration(labelText: s.t('English Name', 'الاسم بالإنجليزية'))),
              const SizedBox(height: 16),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _isUploading ? null : _pickAndUploadTaxCard,
                    icon: const Icon(Icons.upload_file),
                    label: Text(_isUploading ? s.t('Uploading...', 'جاري الرفع...') : s.t('Upload Tax Card / PDF', 'رفع البطاقة الضريبية / PDF')),
                  ),
                  if (_taxCardUrl != null) ...[
                    const SizedBox(width: 10),
                    const Icon(Icons.check_circle, color: Colors.green),
                  ],
                ],
              ),
              const Divider(height: 30),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(s.t('Addresses', 'العناوين'), style: const TextStyle(fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.add_circle, color: Color(0xFF008DDA)),
                    onPressed: () => setState(() => _addresses.add({'type': 'mailing', 'address_ar': '', 'address_en': ''})),
                  ),
                ],
              ),
              ..._addresses.asMap().entries.map((e) {
                final idx = e.key;
                final addr = e.value;
                return Row(
                  children: [
                    DropdownButton<String>(
                      value: addr['type'],
                      items: [
                        DropdownMenuItem(value: 'mailing', child: Text(s.t('Mailing', 'مراسلة'))),
                        DropdownMenuItem(value: 'operation', child: Text(s.t('Operation', 'تشغيل'))),
                      ],
                      onChanged: (v) => setState(() => addr['type'] = v!),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        decoration: InputDecoration(hintText: s.t('Arabic Address', 'العنوان بالعربي')),
                        controller: TextEditingController(text: addr['address_ar'])..selection = TextSelection.collapsed(offset: addr['address_ar']!.length),
                        onChanged: (v) => addr['address_ar'] = v,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        decoration: InputDecoration(hintText: s.t('English Address', 'العنوان بالإنجليزي')),
                        controller: TextEditingController(text: addr['address_en'])..selection = TextSelection.collapsed(offset: addr['address_en']!.length),
                        onChanged: (v) => addr['address_en'] = v,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle, color: Colors.red),
                      onPressed: () => setState(() => _addresses.removeAt(idx)),
                    ),
                  ],
                );
              }),
              const Divider(height: 30),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(s.t('Contacts', 'جهات الاتصال'), style: const TextStyle(fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.add_circle, color: Color(0xFF008DDA)),
                    onPressed: () => setState(() => _contacts.add({'name_ar': '', 'name_en': '', 'role_ar': '', 'role_en': '', 'phone': ''})),
                  ),
                ],
              ),
              ..._contacts.asMap().entries.map((e) {
                final idx = e.key;
                final c = e.value;
                return Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            decoration: InputDecoration(hintText: s.t('Name (Ar)', 'الاسم (عربي)')),
                            controller: TextEditingController(text: c['name_ar'])..selection = TextSelection.collapsed(offset: c['name_ar']!.length),
                            onChanged: (v) => c['name_ar'] = v,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            decoration: InputDecoration(hintText: s.t('Name (En)', 'الاسم (إنجليزي)')),
                            controller: TextEditingController(text: c['name_en'])..selection = TextSelection.collapsed(offset: c['name_en']!.length),
                            onChanged: (v) => c['name_en'] = v,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.remove_circle, color: Colors.red),
                          onPressed: () => setState(() => _contacts.removeAt(idx)),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            decoration: InputDecoration(hintText: s.t('Role (Ar)', 'الوظيفة (عربي)')),
                            controller: TextEditingController(text: c['role_ar'])..selection = TextSelection.collapsed(offset: c['role_ar']!.length),
                            onChanged: (v) => c['role_ar'] = v,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            decoration: InputDecoration(hintText: s.t('Role (En)', 'الوظيفة (إنجليزي)')),
                            controller: TextEditingController(text: c['role_en'])..selection = TextSelection.collapsed(offset: c['role_en']!.length),
                            onChanged: (v) => c['role_en'] = v,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            decoration: InputDecoration(hintText: s.t('Phone', 'الهاتف')),
                            controller: TextEditingController(text: c['phone'])..selection = TextSelection.collapsed(offset: c['phone']!.length),
                            onChanged: (v) => c['phone'] = v,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                );
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('Cancel', 'إلغاء'))),
        ElevatedButton(onPressed: _saveCompany, child: Text(s.t('Save', 'حفظ'))),
      ],
    );
  }
}
