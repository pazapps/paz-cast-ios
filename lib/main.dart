import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';
import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:confetti/confetti.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';
import 'package:share_plus/share_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/foundation.dart' show kIsWeb, setEquals;
import 'package:http/http.dart' as http;

import 'update_service.dart';
import 'tela_inscricao_evento.dart';
//import 'secrets.dart';
import 'firebase_options.dart';
// removed unused import: 'tela_editor_anotacao.dart'
import 'tela_minhas_anotacoes.dart';
import 'tela_checkins_ativos.dart';

// Formata diferentes tipos de valores de hora para formato 24h (HH:mm)
String _formatHora(dynamic h) {
  if (h == null) return '';
  try {
    if (h is DateTime) return DateFormat.Hm().format(h);
    // Firestore Timestamp (avoid importing Timestamp type directly here)
    if (h.runtimeType.toString() == 'Timestamp') {
      final dt = (h as dynamic).toDate() as DateTime;
      return DateFormat.Hm().format(dt);
    }
    final s = h.toString().trim();
    final ampmRegex = RegExp(r'\b(am|pm)\b', caseSensitive: false);
    if (ampmRegex.hasMatch(s)) {
      try {
        final dt = DateFormat.jm('en_US').parse(s);
        return DateFormat.Hm().format(dt);
      } catch (_) {}
    }
    final hmMatch = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(s);
    if (hmMatch != null) {
      final hh = int.tryParse(hmMatch.group(1) ?? '0') ?? 0;
      final mm = int.tryParse(hmMatch.group(2) ?? '0') ?? 0;
      final dt = DateTime(2000, 1, 1, hh, mm);
      return DateFormat.Hm().format(dt);
    }
        return s;
  } catch (e) {
    return h.toString();
  }
}

/// Extrai texto puro de qualquer formato (HTML, Quill JSON ou Texto Simples)
String _extrairTextoPuro(dynamic texto) {
  if (texto == null || texto == '') return '';
  String s = texto.toString();

  // Se for HTML
  if (s.trim().startsWith('<') && s.contains('>')) {
    return s
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#39;', "'");
  }

  // Se for Quill (JSON)
  try {
    final decoded = jsonDecode(s);
    // Quill Delta costuma ser uma lista de operações ou um objeto com 'ops'
    if (decoded is List || (decoded is Map && decoded.containsKey('ops'))) {
      final quillDoc = quill.Document.fromJson(decoded is List ? decoded : decoded['ops']);
      return quillDoc.toPlainText();
    }
  } catch (_) {}

  // Texto puro padrão
  return s;
}

// Simple in-memory + on-disk cache for network images used by the home carousel.
final Map<String, Uint8List> _imageMemoryCache = {};

Future<Directory> get _imageCacheDir async {
  try {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(base.path, 'home_image_cache'));
    if (!(await d.exists())) await d.create(recursive: true);
    return d;
  } catch (e) {
    // Fallback to temporary directory
    final tmp = await getTemporaryDirectory();
    final d = Directory(p.join(tmp.path, 'home_image_cache'));
    if (!(await d.exists())) await d.create(recursive: true);
    return d;
  }
}

Widget _networkImage(
  String imageUrl, {
  double? height,
  double? width,
  BoxFit fit = BoxFit.cover,
}) {
  // Na web, usar Image.network diretamente (mais simples e funciona com CORS)
  if (kIsWeb) {
    return Image.network(
      imageUrl,
      height: height ?? 100,
      width: width ?? 100,
      fit: fit,
      errorBuilder: (context, error, stackTrace) {
        return Container(
          height: height ?? 100,
          width: width ?? 100,
          color: Colors.grey.shade400,
          child: const Center(child: Icon(Icons.broken_image)),
        );
      },
    );
  }

  // No mobile, usar cache em arquivo
  return FutureBuilder<Uint8List?>(
    future: () async {
      // If it's a local file path, read directly from disk
      try {
        final maybeFile = File(imageUrl);
        if (await maybeFile.exists()) {
          final bytes = await maybeFile.readAsBytes();
          _imageMemoryCache[imageUrl] = bytes;
          return bytes;
        }
      } catch (_) {}

      // Check memory cache first
      try {
        final mem = _imageMemoryCache[imageUrl];
        if (mem != null && mem.isNotEmpty) return mem;

        final dir = await _imageCacheDir;
        final filename = Uri.encodeComponent(imageUrl);
        final file = File(p.join(dir.path, filename));
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          _imageMemoryCache[imageUrl] = bytes;
          return bytes;
        }

        // Not cached: fetch
        final uri = Uri.parse(imageUrl);
        final r = await http.get(uri).timeout(const Duration(seconds: 10));
        if (r.statusCode == 200) {
          final bytes = r.bodyBytes;
          try {
            await file.writeAsBytes(bytes, flush: true);
          } catch (_) {}
          _imageMemoryCache[imageUrl] = bytes;
          return bytes;
        }
        debugPrint('Image http.get failed: status=${r.statusCode}, url=$imageUrl');
        return null;
      } catch (e, st) {
        debugPrint('Image cache/fetch exception: $e');
        debugPrintStack(stackTrace: st);
        return null;
      }
    }(),
    builder: (context, snap) {
      if (snap.connectionState == ConnectionState.waiting) {
        return SizedBox(
          height: height ?? 100,
          width: width ?? 100,
          child: const Center(child: CircularProgressIndicator()),
        );
      }
      final bytes = snap.data;
      if (bytes == null || bytes.isEmpty) {
        return Container(
          height: height,
          width: width,
          color: Colors.black12,
          child: const Center(
            child: Icon(Icons.broken_image, color: Colors.white70, size: 36),
          ),
        );
      }
      return Image.memory(bytes, height: height, width: width, fit: fit);
    },
  );
}

    
// --- TELA EDITAR/CRIAR ANOTAÇÃO ---
class TelaEditarAnotacao extends StatefulWidget {
  final String? noteId;
  const TelaEditarAnotacao({super.key, this.noteId});

  @override
  State<TelaEditarAnotacao> createState() => _TelaEditarAnotacaoState();
}

class _TelaEditarAnotacaoState extends State<TelaEditarAnotacao> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  bool _isLoading = false;
  bool _isNew = true;
  String? _userId;
  DocumentReference? _noteRef;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    _userId = user?.uid;
    if (widget.noteId != null) {
      _isNew = false;
      _noteRef = FirebaseFirestore.instance
          .collection('user_notes')
          .doc(widget.noteId);
      _loadNote();
    }
  }

  Future<void> _loadNote() async {
    setState(() => _isLoading = true);
    final doc = await _noteRef!.get();
    if (doc.exists) {
      final note = UserNote.fromFirestore(doc);
      _titleController.text = note.title;
      _contentController.text = note.content is String ? note.content : '';
    }
    setState(() => _isLoading = false);
  }

  Future<void> _autoSave() async {
    if (_userId == null) return;
    final title = _titleController.text.trim();
    final content = _contentController.text;
    final data = {
      'userId': _userId,
      'title': title,
      'content': content,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (_isNew) {
      final ref =
          await FirebaseFirestore.instance.collection('user_notes').add(data);
      if (mounted) {
        setState(() {
          _isNew = false;
          _noteRef = ref;
        });
      }
    } else {
      await _noteRef!.update(data);
    }
  }

  @override
  void dispose() {
    _autoSave();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Nova Anotação' : 'Editar Anotação'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: 'Salvar',
            onPressed: _autoSave,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: 'Título',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => _autoSave(),
                  ),
                  const SizedBox(height: 16),
                  _EditorToolbar(controller: _contentController),
                  const SizedBox(height: 8),
                  Expanded(
                    child: TextField(
                      controller: _contentController,
                      maxLines: null,
                      minLines: 10,
                      expands: true,
                      keyboardType: TextInputType.multiline,
                      decoration: const InputDecoration(
                        labelText: 'Digite sua anotação...',
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                      onChanged: (_) => setState(() {
                        _autoSave();
                      }),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Pré-visualização:',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: HtmlWidget(
                      _markdownToHtml(_contentController.text),
                      textStyle:
                          const TextStyle(fontSize: 15, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// Converte Markdown básico para HTML para pré-visualização
  String _markdownToHtml(String text) {
    String html = text;
    html = html.replaceAllMapped(
        RegExp(r'\*\*(.*?)\*\*'), (m) => '<b>${m[1]}</b>');
    html = html.replaceAllMapped(RegExp(r'_(.*?)_'), (m) => '<i>${m[1]}</i>');
    html = html.replaceAllMapped(RegExp(r'~~(.*?)~~'), (m) => '<s>${m[1]}</s>');
    html = html.replaceAllMapped(RegExp(r'__(.*?)__'), (m) => '<u>${m[1]}</u>');
    html = html.replaceAllMapped(
        RegExp(r'^• (.*)', multiLine: true), (m) => '<li>${m[1]}</li>');
    if (html.contains('<li>')) {
      html = '<ul>${html.replaceAll(RegExp(r'(</li>)(?!<li>)'), '</li>')}</ul>';
    }
    html = html.replaceAll('\n', '<br>');
    return html;
  }
}

/// Toolbar simples para formatação básica
class _EditorToolbar extends StatelessWidget {
  final TextEditingController controller;
  const _EditorToolbar({required this.controller});

  void _wrapSelection(TextEditingController c, String left, String right) {
    final text = c.text;
    final sel = c.selection;
    if (!sel.isValid) return;
    final before = text.substring(0, sel.start);
    final selected = text.substring(sel.start, sel.end);
    final after = text.substring(sel.end);
    final newText = before + left + selected + right + after;
    c.value = c.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(
          offset: (before + left + selected + right).length),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.format_bold),
          tooltip: 'Negrito',
          onPressed: () => _wrapSelection(controller, '**', '**'),
        ),
        IconButton(
          icon: const Icon(Icons.format_italic),
          tooltip: 'Itálico',
          onPressed: () => _wrapSelection(controller, '_', '_'),
        ),
        IconButton(
          icon: const Icon(Icons.format_underline),
          tooltip: 'Sublinhado',
          onPressed: () => _wrapSelection(controller, '__', '__'),
        ),
        IconButton(
          icon: const Icon(Icons.format_strikethrough),
          tooltip: 'Riscado',
          onPressed: () => _wrapSelection(controller, '~~', '~~'),
        ),
        IconButton(
          icon: const Icon(Icons.format_list_bulleted),
          tooltip: 'Lista',
          onPressed: () => _wrapSelection(controller, '\n• ', ''),
        ),
        IconButton(
          icon: const Icon(Icons.content_copy),
          tooltip: 'Copiar',
          onPressed: () {
            final sel = controller.selection;
            final text = sel.isValid && !sel.isCollapsed
                ? controller.text.substring(sel.start, sel.end)
                : controller.text;
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Copiado!')));
          },
        ),
        IconButton(
          icon: const Icon(Icons.content_paste),
          tooltip: 'Colar',
          onPressed: () async {
            final data = await Clipboard.getData('text/plain');
            if (data?.text != null) {
              final c = controller;
              final sel = c.selection;
              final text = c.text;
              final before = text.substring(0, sel.start);
              final after = text.substring(sel.end);
              final newText = before + data!.text! + after;
              c.value = c.value.copyWith(
                text: newText,
                selection: TextSelection.collapsed(
                    offset: (before + data.text!).length),
              );
            }
          },
        ),
      ],
    );
  }
}

/// Modelo de anotação do usuário
class UserNote {
  final String id;
  final String userId;
  final String title;
  final dynamic content; // Quill Delta JSON
  final DateTime updatedAt;

  UserNote({
    required this.id,
    required this.userId,
    required this.title,
    required this.content,
    required this.updatedAt,
  });

  factory UserNote.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return UserNote(
      id: doc.id,
      userId: data['userId'] ?? '',
      title: data['title'] ?? '',
      content: data['content'],
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'userId': userId,
      'title': title,
      'content': content,
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Exibe tela de erro personalizada para erros de widget (evita tela branca)
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: Colors.white,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, color: Colors.red, size: 64),
            SizedBox(height: 16),
            Text(
              'Ocorreu um erro inesperado!',
              style: TextStyle(fontSize: 18, color: Colors.red),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              details.exceptionAsString(),
              style: TextStyle(fontSize: 12, color: Colors.black54),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  };

  // Tenta inicializar o Firebase, mas não deixa a aplicação travar sem internet.
  try {
    await Firebase.initializeApp(
            options: DefaultFirebaseOptions.currentPlatform)
        .timeout(const Duration(seconds: 6));
    debugPrint('Firebase inicializado com sucesso.');
  } catch (e) {
    debugPrint('Aviso: falha/timeout ao inicializar Firebase: $e');
  }

  // Inicialização de formatação de datas com timeout para evitar travamentos
  try {
    await initializeDateFormatting('pt_BR', null)
        .timeout(const Duration(seconds: 3));
  } catch (e) {
    debugPrint('Aviso: falha ao inicializar formatação de datas: $e');
  }

  runApp(const AppRoot());
}

class AppRoot extends StatelessWidget {
  const AppRoot({super.key});
  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _initAll(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const MaterialApp(
            home: Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        if (snapshot.hasError) {
          return MaterialApp(
            home: Scaffold(
              body: Center(
                  child: Text('Erro ao inicializar: \\n${snapshot.error}')),
            ),
          );
        }
        return const AppPazPremium();
      },
    );
  }
}

Future<void> _initAll() async {
  // Removido Firebase.initializeApp daqui pois já foi inicializado no main()
  // Executa inicializações auxiliares, mas trata falhas para não bloquear a UI
  try {
    await _setupFirestorePersistence().timeout(const Duration(seconds: 3));
  } catch (e) {
    debugPrint('Falha ao configurar persistência do Firestore: $e');
  }

  try {
    await _setupPushNotifications().timeout(const Duration(seconds: 6));
  } catch (e) {
    debugPrint('Falha ao configurar push notifications: $e');
  }
}

Future<void> _setupFirestorePersistence() async {
  try {
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
  } catch (e) {
    debugPrint('Falha ao configurar cache offline do Firestore: $e');
  }
}

/// Envia inscrição para a planilha Google Sheets na aba do evento
Future<void> enviarInscricaoParaPlanilha({
  required Map<String, dynamic> data,
  required String nomeAba,
  required String situacao,
}) async {
  const String scriptUrl =
      'https://script.google.com/macros/s/AKfycby6qT98Y78855B2Lcpj0ijNogblTLzs2Ci5i5Hw1hrE_P5Y-U0-rQvS2h-vMRtBeE_phg/exec';
  final body = {
    ...data,
    'sheetName': nomeAba,
    'situacao': situacao,
  };
  try {
    final response = await http.post(
      Uri.parse(scriptUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      debugPrint(
          'Erro ao enviar inscrição para planilha: [${response.statusCode}] ${response.body}');
      throw Exception(
          'Falha ao registrar na planilha (Status: ${response.statusCode})');
    }
  } catch (e) {
    debugPrint('Erro ao enviar inscrição para planilha: $e');
    rethrow;
  }
}

/// Configuração de notificações push Firebase Messaging
Future<void> _setupPushNotifications() async {
  final messaging = FirebaseMessaging.instance;
  // Solicita permissão (necessário para iOS) — protege contra falhas/retries
  try {
    await messaging
        .requestPermission(alert: true, badge: true, sound: true)
        .timeout(const Duration(seconds: 4));
  } catch (e) {
    debugPrint('Aviso: requestPermission falhou ou timeout: $e');
  }

  // Inicializa handlers (não bloqueantes)
  try {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      if (message.notification != null) {
        print(
            'Notificação recebida: ${message.notification!.title} - ${message.notification!.body}');
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print('Notificação aberta pelo usuário: ${message.notification?.title}');
    });

    // Handler para background/terminated (deve ser top-level)
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint('Aviso: falha ao configurar handlers de FCM: $e');
  }

  // (Opcional) Inscreve em um tópico global (exceto web)
  if (!kIsWeb) {
    try {
      await messaging.subscribeToTopic('todos').timeout(const Duration(seconds: 4));
    } catch (e) {
      debugPrint('Aviso: subscribeToTopic falhou ou timeout: $e');
    }
  }
}

/// Handler para notificações recebidas em background
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print('Notificação recebida em background: ${message.notification?.title}');
}

/// Login Google integrado ao Firebase Auth
Future<void> signInWithGoogle(BuildContext context) async {
  try {
    if (kIsWeb) {
      // Web
      GoogleAuthProvider authProvider = GoogleAuthProvider();
      await FirebaseAuth.instance.signInWithPopup(authProvider);
    } else {
      // Mobile
      final googleSignIn = GoogleSignIn();
      await googleSignIn
          .signOut(); // Limpa estado anterior para forçar login fresco
      final GoogleSignInAccount? googleUser = await googleSignIn.signIn();
      if (googleUser == null) return; // Cancelado
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Login Google realizado com sucesso!')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erro no login Google: $e')),
      );
    }
  }
}

/// Função global para envio de dados do Culto para o Google Sheets.
/// Não pode acessar context, apenas retorna erro lançando exceção.
Future<void> sendToCultosSheets(Map<String, dynamic> data) async {
  // Relatório de Culto
  const String scriptUrl =
      'https://script.google.com/macros/s/AKfycbzx3HjDdBglzkcUGfNu9zIFAqL8QNmzlEcCQJF1Civ5NkR6Xt4pSisJ2nbXz0iiQOBv/exec';
  const String spreadsheetId =
      '12toKDAHQSRRQrOE7nvGk834JVXdqztbXiz2vc5HpyRY'; // ID da sua planilha
  try {
    final response = await http.post(
      Uri.parse(scriptUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'spreadsheetId': spreadsheetId,
        'sheetName': 'Cultos',
        'data': data,
      }),
    );
    if (response.statusCode == 302) {
      debugPrint(
          'Aviso: resposta 302 recebida do Apps Script (redirecionamento).');
      return;
    }
    if (response.statusCode != 200) {
      debugPrint(
          'Erro ao enviar para planilha: [${response.statusCode}] ${response.body}');
      throw Exception('Falha na comunicação com o servidor de planilhas.');
    }
    // Tenta decodificar como JSON, mas não quebra se não for
    try {
      final responseData = jsonDecode(response.body);
      if (responseData is Map &&
          responseData.containsKey('success') &&
          !responseData['success']) {
        debugPrint('Erro na planilha: ${responseData['error']}');
      }
    } catch (e) {
      debugPrint('Resposta não JSON da planilha: ${response.body}');
    }
  } catch (e) {
    debugPrint('Erro ao enviar para planilha: $e');
  }
}

// --- TELA RELATÓRIO DIFLEN ---
class TelaRelatorioDiflen extends StatefulWidget {
  const TelaRelatorioDiflen({super.key});
  @override
  State<TelaRelatorioDiflen> createState() => _TelaRelatorioDiflenState();
}

class _TelaRelatorioDiflenState extends State<TelaRelatorioDiflen> {
  final _formKey = GlobalKey<FormState>();
  DateTime _data = DateTime.now();
  final _dataController = TextEditingController();
  final _nomeCultoController = TextEditingController();
  final _presentesController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _dataController.text = DateFormat('dd/MM/yyyy').format(_data);
  }

  @override
  void dispose() {
    _dataController.dispose();
    _nomeCultoController.dispose();
    _presentesController.dispose();
    super.dispose();
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _data,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      locale: const Locale('pt', 'BR'),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.dark(
              primary: Color(0xFF005BFF),
              onPrimary: Colors.white,
              surface: Color(0xFF1E293B),
              onSurface: Colors.white,
            ),
            dialogBackgroundColor: Color(0xFF0F2C59),
            textTheme:
                Theme.of(context).textTheme.apply(bodyColor: Colors.white),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        _data = picked;
        _dataController.text = DateFormat('dd/MM/yyyy').format(_data);
      });
    }
  }

  Future<void> _submitForm() async {
    if (!_formKey.currentState!.validate()) return;

    final nome = _nomeCultoController.text.trim();
    final presentesStr = _presentesController.text.trim();
    final presentes = int.tryParse(presentesStr);
    if (presentes == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Preencha todos os campos numéricos corretamente!'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    setState(() => _isLoading = true);
    try {
      // Salva no Firestore
      final user = FirebaseAuth.instance.currentUser;
      final relatorioData = {
        'data': DateFormat('dd/MM/yyyy').format(_data),
        'nome_do_culto': nome,
        'presentes': presentes,
        'user_id': user?.uid,
        'user_name':
            user?.displayName ?? user?.email?.split('@').first ?? 'Anônimo',
        'timestamp': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance
          .collection('relatorios_diflen')
          .add(relatorioData);

      // Remove o campo 'timestamp' para enviar à planilha
      final relatorioDataPlanilha = Map<String, dynamic>.from(relatorioData);
      relatorioDataPlanilha.remove('timestamp');
      await _sendToDiflenSheets(relatorioDataPlanilha);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Relatório enviado com sucesso!')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao enviar relatório: $e')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _sendToDiflenSheets(Map<String, dynamic> data) async {
    // Relatório DIFLEN (padronizado)
    const String scriptUrl =
        'https://script.google.com/macros/s/AKfycbyCE5D6ciL1M32GSfL68QkRQQ1nFfOqBZK04cUWXm94YPT2jyBWE-1nZBtkJxggimnsgw/exec';
    const String spreadsheetId =
        '1JdZSJNiMwepVRZBxfQ-GHouTe-u28JBORP3SvFHnuYc'; // Substitua pelo ID correto da planilha DIFLEN
    try {
      final response = await http.post(
        Uri.parse(scriptUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'spreadsheetId': spreadsheetId,
          'sheetName': 'DIFLEN',
          'data': data,
        }),
      );
      if (response.statusCode != 200) {
        throw Exception(
            'Erro ao enviar para planilha DIFLEN: \u001b[${response.statusCode}]');
      }
      final responseData = jsonDecode(response.body);
      if (!(responseData['success'] ?? false)) {
        throw Exception(
            'Erro Apps Script DIFLEN: \u001b[${responseData['error']}');
      }
    } catch (e) {
      debugPrint('Erro ao enviar para planilha DIFLEN: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Aviso: Relatório salvo localmente $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Relatório DIFLEN')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text('Data:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _selectDate(context),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 14, horizontal: 16),
                      decoration: BoxDecoration(
                        color: Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            DateFormat('dd/MM/yyyy', 'pt_BR').format(_data),
                            style: const TextStyle(
                                fontSize: 16, color: Colors.white),
                          ),
                          const Icon(Icons.calendar_today,
                              color: Colors.amber, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _nomeCultoController,
              decoration: const InputDecoration(labelText: 'Nome do Culto'),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Campo obrigatório';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _presentesController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Presentes'),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Campo obrigatório';
                }
                if (int.tryParse(value.trim()) == null) {
                  return 'Digite um número válido';
                }
                return null;
              },
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.send),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                textStyle:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              onPressed: _isLoading ? null : _submitForm,
              label: _isLoading
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Enviar Relatório'),
            ),
          ],
        ),
      ),
    );
  }
}

// --- TELA RELATÓRIO DO CULTO ---
class TelaRelatorioCulto extends StatefulWidget {
  const TelaRelatorioCulto({super.key});
  @override
  State<TelaRelatorioCulto> createState() => _TelaRelatorioCultoState();
}

class _TelaRelatorioCultoState extends State<TelaRelatorioCulto> {
  final _formKey = GlobalKey<FormState>();
  DateTime _data = DateTime.now();
  String _culto = 'Manhã';
  final _presentesController = TextEditingController();
  final _pazkidsController = TextEditingController();
  final _tadelController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _presentesController.dispose();
    _pazkidsController.dispose();
    _tadelController.dispose();
    super.dispose();
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _data,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      locale: const Locale('pt', 'BR'),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.dark(
              primary: Color(0xFF005BFF),
              onPrimary: Colors.white,
              surface: Color(0xFF1E293B),
              onSurface: Colors.white,
            ),
            dialogBackgroundColor: Color(0xFF0F2C59),
            textTheme:
                Theme.of(context).textTheme.apply(bodyColor: Colors.white),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) setState(() => _data = picked);
  }

  Future<void> _submitForm() async {
    if (!_formKey.currentState!.validate()) return;

    final presentesStr = _presentesController.text.trim();
    final pazkidsStr = _pazkidsController.text.trim();
    final tadelStr = _tadelController.text.trim();
    final presentes = int.tryParse(presentesStr);
    final pazkids = int.tryParse(pazkidsStr);
    final tadel = int.tryParse(tadelStr);
    if (presentes == null || pazkids == null || tadel == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Preencha todos os campos numéricos corretamente!'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    setState(() => _isLoading = true);
    try {
      // Salva no Firestore
      final user = FirebaseAuth.instance.currentUser;
      final relatorioData = {
        'data': DateFormat('dd/MM/yyyy').format(_data),
        'culto': _culto,
        'presentes': presentes,
        'pazkids': pazkids,
        'tadel': tadel,
        'user_id': user?.uid,
        'user_name':
            user?.displayName ?? user?.email?.split('@').first ?? 'Anônimo',
        'timestamp': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance
          .collection('relatorios_culto')
          .add(relatorioData);

      // Remove o campo 'timestamp' para enviar à planilha
      final relatorioDataPlanilha = Map<String, dynamic>.from(relatorioData);
      relatorioDataPlanilha.remove('timestamp');
      await sendToCultosSheets(relatorioDataPlanilha);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Relatório enviado com sucesso!')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao enviar relatório: $e')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Relatório do Culto')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text('Data do Culto',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _selectDate(context),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                decoration: BoxDecoration(
                  color: Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white24),
                ),
                child: Text(
                  DateFormat('dd/MM/yyyy', 'pt_BR').format(_data),
                  style: const TextStyle(fontSize: 16, color: Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text('Culto', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _culto,
              items: const [
                DropdownMenuItem(value: 'Manhã', child: Text('Manhã')),
                DropdownMenuItem(value: 'Noite', child: Text('Noite')),
              ],
              onChanged: (v) => setState(() => _culto = v ?? 'Manhã'),
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _presentesController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Quantidade de pessoas',
                labelText: 'Presentes',
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Campo obrigatório';
                }
                if (int.tryParse(value.trim()) == null) {
                  return 'Digite um número válido';
                }
                return null;
              },
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _pazkidsController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Quantidade de crianças',
                labelText: 'PazKids',
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Campo obrigatório';
                }
                if (int.tryParse(value.trim()) == null) {
                  return 'Digite um número válido';
                }
                return null;
              },
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _tadelController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Quantidade Tadel',
                labelText: 'Tadel',
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Campo obrigatório';
                }
                if (int.tryParse(value.trim()) == null) {
                  return 'Digite um número válido';
                }
                return null;
              },
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              icon: const Icon(Icons.send),
              onPressed: _isLoading ? null : _submitForm,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 18),
                textStyle:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              label: _isLoading
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Enviar Relatório'),
            ),
          ],
        ),
      ),
    );
  }
}

// --- TELA DE PAGAMENTO PIX ---

class TelaPagamentoPix extends StatefulWidget {
  final double valor;
  final String inscricaoId;
  final String? nome;
  final String? nascimento;
  final String? celular;
  final String? nomeEvento;
  final Future<void> Function()? onPagamentoConfirmado;
  const TelaPagamentoPix({
    super.key,
    required this.valor,
    required this.inscricaoId,
    this.nome,
    this.nascimento,
    this.celular,
    this.nomeEvento,
    this.onPagamentoConfirmado,
  });

  @override
  State<TelaPagamentoPix> createState() => _TelaPagamentoPixState();
}

class _TelaPagamentoPixState extends State<TelaPagamentoPix> {
  late Future<Map<String, dynamic>> _pixFuture;

  @override
  void initState() {
    super.initState();
    _pixFuture = _gerarPix();
  }

  Future<Map<String, dynamic>> _gerarPix() async {
    // Chama o novo backend para gerar o Pix
    final response = await http.post(
      Uri.parse('https://paz-payment.onrender.com/criar-pix'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'valor': widget.valor,
        'inscricaoId': widget.inscricaoId,
        'nome': widget.nome,
        'nascimento': widget.nascimento,
        'celular': widget.celular,
        'nomeEvento': widget.nomeEvento,
      }),
    );
    if (response.statusCode != 200) {
      throw Exception('Erro ao gerar Pix: ${response.body}');
    }
    return jsonDecode(response.body);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pagamento PIX'),
        backgroundColor: Colors.transparent,
      ),
      backgroundColor: const Color(0xFF020617),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _pixFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('Erro: ${snapshot.error}',
                  style: const TextStyle(color: Colors.red)),
            );
          }
          final data = snapshot.data ?? {};
          final qrCodeImageUrl = data['qrCodeImageUrl'] as String?;
          final copiaECola = data['copiaECola'] as String?;
          final pagamentoConfirmado = data['pagamentoConfirmado'] == true;
          if (pagamentoConfirmado && widget.onPagamentoConfirmado != null) {
            // Chama o callback e evita múltiplas execuções
            WidgetsBinding.instance.addPostFrameCallback((_) {
              widget.onPagamentoConfirmado!();
            });
          }
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: _GlassCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.pix, color: Color(0xFF00BFA5), size: 48),
                    const SizedBox(height: 16),
                    Text('Valor: R\$ ${widget.valor.toStringAsFixed(2)}',
                        style: const TextStyle(
                            fontSize: 22,
                            color: Colors.amber,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 24),
                    if (qrCodeImageUrl != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: _networkImage(
                          qrCodeImageUrl,
                          height: 220,
                          width: 220,
                          fit: BoxFit.contain,
                        ),
                      ),
                    if (copiaECola != null) ...[
                      const SizedBox(height: 24),
                      SelectableText(copiaECola,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14)),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: copiaECola));
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Código PIX copiado!')));
                        },
                        icon: const Icon(Icons.copy),
                        label: const Text('Copiar código PIX'),
                      ),
                    ],
                    if (pagamentoConfirmado)
                      const Padding(
                        padding: EdgeInsets.only(top: 24),
                        child: Text(
                          'Pagamento confirmado! Aguarde a mensagem de confirmação.',
                          style: TextStyle(
                              color: Colors.green,
                              fontSize: 16,
                              fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    const SizedBox(height: 24),
                    const Text(
                        'Após o pagamento, a confirmação pode levar alguns minutos.',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class AppPazPremium extends StatelessWidget {
  const AppPazPremium({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF005BFF), brightness: Brightness.dark),
      ),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('pt', 'BR'),
      ],
      home: const TelaSplash(),
    );
  }
}

// --- 1. TELA DE SPLASH ---
class TelaSplash extends StatefulWidget {
  const TelaSplash({super.key});
  @override
  State<TelaSplash> createState() => _TelaSplashState();
}

class _TelaSplashState extends State<TelaSplash> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (context) => const MainScaffold()));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 23, 52, 184),
      body: Center(
          child: Image.asset('assets/icon.png',
              width: 220, filterQuality: FilterQuality.high)),
    );
  }
}

// --- 2. SCAFFOLD PRINCIPAL ---
class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});
  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _currentIndex = 0;
  bool _isReadingMode = false;
  bool _navHidden = false;
  bool _hasShownStartupMessage = false;

    @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _showStartupMessage();
        UpdateService().checkForUpdates(context);
      }
    });
  }

  void _showStartupMessage() {
    if (_hasShownStartupMessage) return;
    _hasShownStartupMessage = true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 90),
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.white.withOpacity(0.08),
        content: const Text(
          'Usando dados já atualizados. Sem internet o app continua funcionando.',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
      ),
    );
  }

  void _mudarTela(int i) {
    setState(() {
      _currentIndex = i;
      _isReadingMode = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      TelaInicio(onNavigate: _mudarTela),
      const TelaAvisosPro(),
      const TelaAgendaPro(),
      TelaBibliaPro(
          onReading: (b) => setState(() => _isReadingMode = b),
          onNavigate: _mudarTela),
      const AbaMembroFull(),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF020617),
      extendBody: true,
      body: Stack(children: [
        Positioned.fill(
            child: Container(
                decoration: const BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF0F2C59), Color(0xFF061224)])))),
        AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                try {
                  if (n.metrics.axis == Axis.vertical) {
                    if (n is UserScrollNotification) {
                      final dirStr = n.direction.toString();
                      if (dirStr.endsWith('.reverse') && !_navHidden) {
                        setState(() => _navHidden = true);
                      } else if (dirStr.endsWith('.forward') && _navHidden) {
                        setState(() => _navHidden = false);
                      }
                    }
                  }
                } catch (_) {}
                return false;
                
              },
              child: KeyedSubtree(
                  key: ValueKey(_currentIndex), child: pages[_currentIndex]),
            )),
      ]),
      bottomNavigationBar: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        height: (_isReadingMode || _navHidden) ? 0 : 110,
        child: (_isReadingMode || _navHidden) ? const SizedBox.shrink() : _buildModernNav(),
      ),
      // Quick access button when nav is hidden
      floatingActionButton: _navHidden
          ? FloatingActionButton(
              onPressed: () => setState(() => _navHidden = false),
              backgroundColor: const Color(0xFF005BFF),
              child: const Icon(Icons.menu),
            )
          : null,
    );
  }

  Widget _buildModernNav() {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 30),
      height: 65,
      decoration: BoxDecoration(
          color: Colors.white.withAlpha(15),
          borderRadius: BorderRadius.circular(25),
          border: Border.all(color: Colors.white.withAlpha(30))),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
        _navBtn(0, Icons.home_filled),
        _navBtn(1, Icons.notifications),
        _navBtn(2, Icons.event),
        _navBtn(3, Icons.menu_book),
        _navBtn(4, Icons.person),
      ]),
    );
  }

  Widget _navBtn(int index, IconData icon) {
    bool isSel = _currentIndex == index;
    return GestureDetector(
        onTap: () => _mudarTela(index),
        child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: isSel ? const Color(0xFF005BFF) : Colors.transparent,
                shape: BoxShape.circle),
            child: Icon(icon,
                color: isSel ? Colors.white : Colors.white.withAlpha(80),
                size: 24)));
  }
}

// --- 3. TELA INICIAL (HOME) ---

class TelaInicio extends StatefulWidget {
  final Function(int) onNavigate;
  const TelaInicio({super.key, required this.onNavigate});

  @override
  State<TelaInicio> createState() => _TelaInicioState();
}

class _TelaInicioState extends State<TelaInicio> {
  List<String>? _homeImages;
  bool _loadingImages = true;
  PageController? _pageController;
  Timer? _carouselTimer;
  int _currentPage = 0;
  Future<List<Map<String, dynamic>>>? _versiculosFuture;

  String _saudacao() {
    var h = DateTime.now().hour;
    if (h < 12) return "Bom dia";
    if (h < 18) return "Boa tarde";
    return "Boa noite";
  }

  Future<List<Map<String, dynamic>>> _buscarVersiculos() async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = 'cached_versiculos_v1';
    final url = Uri.parse(
        'https://script.google.com/macros/s/AKfycbxBh9oXwVsLS0tsUftDeZ-GEAIeTy7IZoKt0I9771R_5l3SaSEFC2rrb0kS76Nvjik/exec');
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        // Save to prefs for offline use
        try {
          await prefs.setString(cacheKey, response.body);
        } catch (_) {}
        return data.cast<Map<String, dynamic>>();
      }
    } catch (_) {}

    // Fallback to cache
    final cached = prefs.getString(cacheKey);
    if (cached != null && cached.isNotEmpty) {
      try {
        final List<dynamic> data = jsonDecode(cached);
        return data.cast<Map<String, dynamic>>();
      } catch (_) {}
    }
    return <Map<String, dynamic>>[];
  }

  @override
  void initState() {
    super.initState();
    _loadHomeImages();
    _versiculosFuture = _buscarVersiculos();
  }

  Future<void> _loadHomeImages() async {
    try {
      final bucket = 'pazcastanhal-809cd.firebasestorage.app';
      final listUrl = Uri.parse('https://firebasestorage.googleapis.com/v0/b/$bucket/o?prefix=home_images/');
      final cacheDir = await _imageCacheDir;

      // load existing cached files
      final entities = await cacheDir.list().toList();
      final cachedFiles = entities.whereType<File>().toList();

      // Try fetch remote list (only at app load). If fails, fallback to cache.
      List<String> remoteNames = [];
      try {
        final resp = await http.get(listUrl).timeout(const Duration(seconds: 8));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          final items = (data['items'] as List<dynamic>?) ?? [];
          remoteNames = items.map<String>((it) => it['name'] as String).toList();
        }
      } catch (_) {}

      final List<String> finalLocalPaths = [];

      if (remoteNames.isNotEmpty) {
        // Ensure we have all remote images downloaded; download missing ones
        for (final name in remoteNames) {
          final remoteUrl = 'https://firebasestorage.googleapis.com/v0/b/$bucket/o/${Uri.encodeComponent(name)}?alt=media';
          final filename = Uri.encodeComponent(remoteUrl);
          final f = File(p.join(cacheDir.path, filename));
          if (await f.exists()) {
            finalLocalPaths.add(f.path);
          } else {
            try {
              final r = await http.get(Uri.parse(remoteUrl)).timeout(const Duration(seconds: 12));
              if (r.statusCode == 200) {
                await f.writeAsBytes(r.bodyBytes, flush: true);
                finalLocalPaths.add(f.path);
              }
            } catch (_) {}
          }
        }
      }

      // If remote failed or no remote images, use cached files found before
      if (finalLocalPaths.isEmpty && cachedFiles.isNotEmpty) {
        finalLocalPaths.addAll(cachedFiles.map((f) => f.path));
      }

      if (!mounted) return;
      setState(() {
        _homeImages = finalLocalPaths;
        _loadingImages = false;
      });

      if (_homeImages != null && _homeImages!.length > 1) {
        _pageController = PageController();
        _carouselTimer = Timer.periodic(const Duration(seconds: 5), (_) {
          if (!mounted) return;
          _currentPage = (_currentPage + 1) % _homeImages!.length;
          _pageController?.animateToPage(_currentPage,
              duration: const Duration(milliseconds: 600), curve: Curves.easeInOut);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _homeImages = [];
        _loadingImages = false;
      });
    }
  }

  @override
  void dispose() {
    _carouselTimer?.cancel();
    _pageController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _versiculosFuture ?? _buscarVersiculos(),
      builder: (context, snap) {
        Widget banner;
        if (_loadingImages) {
          banner = const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()));
        } else if (_homeImages != null && _homeImages!.isNotEmpty) {
            if (_homeImages!.length == 1) {
            final imageUrl = _homeImages!.first;
            banner = Container(
              height: 160,
              width: double.infinity,
              decoration: BoxDecoration(
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                  child: InkWell(
                  onTap: null,
                  child: Stack(fit: StackFit.expand, children: [
                    _networkImage(imageUrl, height: 160, fit: BoxFit.cover),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withOpacity(0.04),
                            Colors.black.withOpacity(0.20),
                          ],
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            );
          } else {
            banner = Container(
              height: 160,
              width: double.infinity,
              decoration: BoxDecoration(
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: PageView.builder(
                controller: _pageController,
                itemCount: _homeImages!.length,
                onPageChanged: (i) {
                  setState(() {
                    _currentPage = i;
                  });
                },
                itemBuilder: (c, i) => _networkImage(_homeImages![i], height: 160, fit: BoxFit.cover),
              ),
            );
          }
        } else {
          if (snap.hasData && snap.data!.isNotEmpty) {
            banner = _buildVerses(snap.data!);
          } else {
            banner = const SizedBox.shrink();
          }
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 25),
          child: Column(children: [
            const SizedBox(height: 50),
            Center(child: Image.asset('assets/icon.png', height: 75)),
            const SizedBox(height: 25),
            if (user != null)
              FutureBuilder<DocumentSnapshot>(
                future: FirebaseFirestore.instance.collection('usuarios').doc(user.uid).get(),
                builder: (c, us) {
                  if (us.connectionState == ConnectionState.waiting) {
                    return Text("${_saudacao()}, carregando...",
                        style: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold));
                  }
                  if (us.hasError) {
                    return Text("${_saudacao()}, ${user.displayName ?? user.email?.split('@').first ?? 'Membro'}!",
                        style: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold));
                  }
                  if (!us.hasData || !us.data!.exists) {
                    return Text("${_saudacao()}, ${user.displayName ?? user.email?.split('@').first ?? 'Membro'}!",
                        style: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold));
                  }
                  Map<String, dynamic>? u = us.data!.data() as Map<String, dynamic>?;
                  String? nome = u?['nome']?.toString().trim();
                  if (nome != null && nome.isNotEmpty) {
                    return Text("${_saudacao()}, $nome!",
                        style: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold));
                  }
                  return Text("${_saudacao()}, ${user.displayName ?? user.email?.split('@').first ?? 'Membro'}!",
                      style: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold));
                },
              )
            else
              Text("${_saudacao()}! Paz!", style: const TextStyle(fontSize: 18, color: Colors.white70)),
            const SizedBox(height: 20),
            if (snap.connectionState == ConnectionState.waiting) const Center(child: CircularProgressIndicator()),
            if (snap.hasError) Text('Erro ao carregar versículos', style: TextStyle(color: Colors.red)),
            banner,
            // Indicadores do carrossel (pontos) - agora tocáveis
            if (_homeImages != null && _homeImages!.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_homeImages!.length, (i) {
                    final isActive = i == _currentPage;
                    return GestureDetector(
                      onTap: () {
                        _pageController?.animateToPage(i,
                            duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: isActive ? 10 : 8,
                        height: isActive ? 10 : 8,
                        decoration: BoxDecoration(
                          color: isActive ? Colors.white : Colors.white54,
                          shape: BoxShape.circle,
                          boxShadow: isActive
                              ? [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 4)]
                              : null,
                        ),
                      ),
                    );
                  }),
                ),
              ),
            const SizedBox(height: 30),
            Wrap(spacing: 15, runSpacing: 15, children: () {
              final actions = [
                {'icon': Icons.menu_book, 'label': 'Bíblia', 'tap': () => widget.onNavigate(3)},
                {'icon': Icons.event, 'label': 'Agenda', 'tap': () => widget.onNavigate(2)},
                {'icon': Icons.groups_3, 'label': 'Célula', 'tap': () => Navigator.push(context, MaterialPageRoute(builder: (c) => const TelaHubCelula()))},
                {'icon': Icons.chat, 'label': 'Contato', 'tap': () => launchUrl(Uri.parse('https://wa.me/5591988629296'), mode: LaunchMode.externalApplication)},
                {'icon': Icons.school, 'label': 'Cursos', 'tap': () => launchUrl(Uri.parse('https://pazbibleschool.com'), mode: LaunchMode.inAppBrowserView)},
                {'icon': Icons.auto_stories, 'label': 'Devocional', 'tap': () => Navigator.push(context, MaterialPageRoute(builder: (c) => const TelaListaDoc(coll: 'devocionais', title: 'Devocionais')))},
                {'icon': Icons.shopping_bag, 'label': 'Loja', 'tap': () => Navigator.push(context, MaterialPageRoute(builder: (c) => const TelaLoja()))},
                {'icon': Icons.play_circle_fill, 'label': 'Mensagens', 'tap': () => Navigator.push(context, MaterialPageRoute(builder: (c) => const TelaListaVideos()))},
                {'icon': Icons.volunteer_activism, 'label': 'Ofertas', 'tap': () => Navigator.push(context, MaterialPageRoute(builder: (c) => const TelaFinanceiro()))},
              ];
              // Ordena alfabeticamente por label (case-insensitive)
              actions.sort((a, b) => (a['label'] as String).toLowerCase().compareTo((b['label'] as String).toLowerCase()));

              return List.generate(actions.length, (i) {
                final a = actions[i];
                return _atBtnIndexed(context, a['icon'] as IconData, a['label'] as String, i, a['tap'] as VoidCallback);
              });
            }()),
            const SizedBox(height: 120),
          ]),
        );
      },
    );
  }

  Widget _buildVerses(List<Map<String, dynamic>> versiculos) {
    if (versiculos.isEmpty) {
      return _GlassCard(
        child: Text('Nenhum versículo disponível',
            style: TextStyle(color: Colors.white70)),
      );
    }
    // Seleciona um versículo "aleatório" fixo para cada período de 12h
    final now = DateTime.now();
    // 0 = meia-noite até 11:59, 1 = meio-dia até 23:59
    final period = now.hour < 12 ? 0 : 1;
    // Usa o dia, mês, ano e o período para gerar um índice pseudoaleatório
    final seed = now.year * 10000 + now.month * 10 + now.day * 10 + period;
    final idx = seed % versiculos.length;
    final v = versiculos[idx];
    return _GlassCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.format_quote, color: Colors.amber),
          SelectableText(v['versiculo'] ?? "...",
              textAlign: TextAlign.center,
              style: GoogleFonts.notoSerif(
                  fontSize: 16,
                  color: Colors.white,
                  fontStyle: FontStyle.italic)),
          Text(v['referencia'] ?? "",
              style: const TextStyle(
                  color: Colors.amber, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildVerse(Map d) => _GlassCard(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.format_quote, color: Colors.amber),
        SelectableText(d['versiculo'] ?? "O Senhor é o meu pastor...",
            textAlign: TextAlign.center,
            style: GoogleFonts.notoSerif(
                fontSize: 16,
                color: Colors.white,
                fontStyle: FontStyle.italic)),
        Text(d['referencia'] ?? "",
            style: const TextStyle(
                color: Colors.amber, fontWeight: FontWeight.bold)),
      ]));

  Widget _atBtn(
      BuildContext context, IconData i, String l, Color c, VoidCallback t,
      {bool verticalGradient = false}) {
    final hsl = HSLColor.fromColor(c);
    final light = hsl.withLightness((hsl.lightness + 0.18).clamp(0.0, 1.0)).toColor();
    final dark = hsl.withLightness((hsl.lightness - 0.18).clamp(0.0, 1.0)).toColor();

    return SizedBox(
        width: (MediaQuery.of(context).size.width - 85) / 3,
        child: InkWell(
            onTap: t,
            child: Column(children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [light, dark],
                      begin: verticalGradient ? Alignment.topCenter : Alignment.centerLeft,
                      end: verticalGradient ? Alignment.bottomCenter : Alignment.centerRight,
                    ),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: [
                      BoxShadow(
                        color: dark.withAlpha(60),
                        offset: const Offset(0, 4),
                        blurRadius: 8,
                      )
                    ]),
                child: Icon(i, color: Colors.white),
              ),
              const SizedBox(height: 8),
              Text(l,
                  style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white,
                      fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center),
            ])));
  }

  Widget _atBtnIndexed(BuildContext context, IconData i, String l, int index, VoidCallback t) {
    const palette = [Color(0xFF005BFF), Color(0xFF00D2FF), Color(0xFF00ECC6)];
    const columns = 3;
    final base = palette[index % columns];
    // On the home page we want vertical gradient orientation for the icons
    return _atBtn(context, i, l, base, t, verticalGradient: true);
  }
}

// --- 4. AGENDA ---
class TelaAgendaPro extends StatelessWidget {
  const TelaAgendaPro({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
          title: const Text("Agenda"), backgroundColor: Colors.transparent),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('agenda')
            .orderBy('dataEvento')
            .snapshots(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          // Ordenar manualmente por dataEvento (caso Firestore não ordene corretamente)
          final docs = snap.data!.docs.toList();
          docs.sort((a, b) {
            final aData = a['dataEvento'];
            final bData = b['dataEvento'];
            if (aData is Timestamp && bData is Timestamp) {
              return aData.toDate().compareTo(bData.toDate());
            }
            return 0;
          });
          return ListView.builder(
            padding: const EdgeInsets.all(25),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              var ev = docs[i].data() as Map? ?? {};
              if (ev.isEmpty) return const SizedBox.shrink();
              // Extrair dia, mês e calcular diferença de dias
              String dia = "";
              String mes = "";
              DateTime? dataEvento;
              DateTime? dataEventoFim;
              int? diasRestantes;
              if (ev['dataEvento'] != null && ev['dataEvento'] is Timestamp) {
                dataEvento = (ev['dataEvento'] as Timestamp).toDate();
                dia = dataEvento.day.toString().padLeft(2, '0');
                mes = DateFormat.MMM('pt_BR').format(dataEvento).toUpperCase();
                final hoje = DateTime.now();
                diasRestantes = dataEvento
                    .difference(DateTime(hoje.year, hoje.month, hoje.day))
                    .inDays;
              }
              // data de fim (eventos de vários dias)
              if (ev['dataEventoFim'] != null && ev['dataEventoFim'] is Timestamp) {
                dataEventoFim = (ev['dataEventoFim'] as Timestamp).toDate();
              }
              // Definir cor do card
              Color cardColor = Colors.blueAccent.withOpacity(0.15);
              Color textColor = Colors.white;
              bool isPast = false;
              Widget? destaque;
              if (diasRestantes != null) {
                if (diasRestantes < 0) {
                  // Evento já passou
                  cardColor = Colors.grey.shade800.withOpacity(0.5);
                  textColor = Colors.grey;
                  isPast = true;
                } else if (diasRestantes <= 3) {
                  // Evento em menos de 3 dias
                  cardColor = Colors.redAccent.withOpacity(0.7);
                  destaque = Padding(
                    padding: const EdgeInsets.only(bottom: 4.0),
                    child: Row(
                      children: const [
                        Icon(Icons.warning, color: Colors.yellow, size: 18),
                        SizedBox(width: 6),
                        Text('EM BREVE!',
                            style: TextStyle(
                                color: Colors.yellow,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  );
                }
              }
              return Opacity(
                opacity: isPast ? 0.6 : 1.0,
                child: Card(
                  color: cardColor,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Date column
                        Container(
                          width: 72,
                          padding: const EdgeInsets.only(left: 6, right: 6),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(dia.isNotEmpty ? dia : "--",
                                  style: TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.bold,
                                      color: isPast ? Colors.grey : const Color(0xFF00D2FF))),
                              const SizedBox(height: 6),
                              Text(mes.isNotEmpty ? mes : "MES",
                                  style: TextStyle(fontSize: 12, color: isPast ? Colors.grey : Colors.white70)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Main content
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (destaque != null) destaque,
                              Text(ev['titulo']?.toString() ?? "Evento",
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: textColor)),
                              const SizedBox(height: 8),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Icon(Icons.access_time, size: 14, color: Colors.amber.shade200),
                                  const SizedBox(width: 6),
                                  Flexible(child: Text(_formatHora(ev['hora']), style: TextStyle(color: Colors.amber))),
                                  const SizedBox(width: 12),
                                  // Multi-day compact dates (dd/MM) shown on same line
                                  if (ev['variosDias'] == true && dataEvento != null)
                                    Flexible(
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                            decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(12)),
                                            child: Text(DateFormat('dd/MM').format(dataEvento),
                                                style: const TextStyle(fontSize: 12, color: Colors.white70)),
                                          ),
                                          if (dataEventoFim != null) ...[
                                            const SizedBox(width: 6),
                                            const Icon(Icons.arrow_forward_ios, size: 12, color: Colors.white70),
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                              decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(12)),
                                              child: Text(DateFormat('dd/MM').format(dataEventoFim),
                                                  style: const TextStyle(fontSize: 12, color: Colors.white70)),
                                            ),
                                          ]
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              if (ev['local'] != null && ev['local'].toString().isNotEmpty)
                                Text(ev['local'].toString(), style: TextStyle(color: Colors.white70)),
                              const SizedBox(height: 6),
                              if (ev['valor'] != null && ev['valor'].toString().isNotEmpty)
                                Text("Valor: R\$${ev['valor']}", style: const TextStyle(color: Colors.greenAccent, fontSize: 14)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Actions column with fixed width; share icon aligned top-right
                        SizedBox(
                          width: 84,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Align(
                                alignment: Alignment.topRight,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (ev['inscricao'] == true)
                                      GestureDetector(
                                        onTap: () {
                                          final valor = ev['valor'] != null
                                              ? double.tryParse(ev['valor'].toString().replaceAll(',', '.')) ?? 0.0
                                              : 0.0;
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (c) => TelaInscricaoEvento(
                                                inscricaoId: docs[i].id,
                                                valor: valor > 0 ? valor : 0,
                                                nomeEvento: ev['titulo']?.toString() ?? 'Evento',
                                                formaPagamento: valor > 0 ? FormaPagamento.pix : FormaPagamento.gratuito,
                                              ),
                                            ),
                                          );
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(
                                            color: Colors.green.shade600,
                                            borderRadius: BorderRadius.circular(8),
                                            boxShadow: [
                                              BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 3, offset: Offset(0, 1)),
                                            ],
                                          ),
                                          child: const Icon(Icons.how_to_reg, size: 16, color: Colors.white),
                                        ),
                                      ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: const Icon(Icons.share, size: 20),
                                      onPressed: () {
                                        final titulo = ev['titulo']?.toString() ?? 'Evento';
                                        final horaStr = _formatHora(ev['hora']);
                                        String quando;
                                        bool isMultiDay = false;
                                        if (ev['variosDias'] == true && dataEventoFim != null && dataEvento != null) {
                                          isMultiDay = true;
                                          final inicio = DateFormat('dd/MM').format(dataEvento);
                                          final fim = DateFormat('dd/MM').format(dataEventoFim);
                                          quando = '$inicio até $fim';
                                        } else if (dataEvento != null) {
                                          quando = DateFormat('dd/MM').format(dataEvento);
                                        } else {
                                          quando = '$dia/$mes';
                                        }
                                        String texto;
                                        if (isMultiDay && horaStr.isNotEmpty) {
                                          texto = 'Você é nosso convidado para $titulo de $quando às $horaStr';
                                        } else if (isMultiDay) {
                                          texto = 'Você é nosso convidado para $titulo de $quando';
                                        } else if (horaStr.isNotEmpty) {
                                          texto = 'Você é nosso convidado para $titulo em $quando às $horaStr';
                                        } else {
                                          texto = 'Você é nosso convidado para $titulo em $quando';
                                        }
                                        Share.share(texto);
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// --- 5. BÍBLIA TABELA PERIÓDICA + GAME ---
class TelaBibliaPro extends StatefulWidget {
  final Function(bool) onReading;
  final Function(int) onNavigate;
  const TelaBibliaPro(
      {super.key, required this.onReading, required this.onNavigate});
  @override
  State<TelaBibliaPro> createState() => _TelaBibliaProState();
}

class _TelaBibliaProState extends State<TelaBibliaPro> {
  // Lista de versículos marcados (por capítulo)
  Set<int> _versiculosMarcados = {};
  // Chave para persistência local
  String get _marcadosKey => 'marcados_${_l?['abbrev'] ?? ''}_${_c ?? ''}';
  // Tela inicial da Bíblia: lista de livros
  Widget _buildHome() {
    return GridView.builder(
      padding: const EdgeInsets.all(25),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.2,
      ),
      itemCount: _livros.length,
      itemBuilder: (context, i) {
        final livro = _livros[i];
        return InkWell(
          onTap: () {
            setState(() {
              _l = livro;
              _c = null;
            });
            widget.onReading(true);
          },
          child: Container(
            decoration: BoxDecoration(
              color: _cor(i).withOpacity(0.18),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _cor(i).withOpacity(0.4)),
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _siglas[i],
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    livro['name'] ?? '',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List _livros = [];
  Map? _l;
  int? _c;
  final List<String> _siglas = [
    "Gn",
    "Ex",
    "Lv",
    "Nm",
    "Dt",
    "Js",
    "Jz",
    "Rt",
    "1Sm",
    "2Sm",
    "1Rs",
    "2Rs",
    "1Cr",
    "2Cr",
    "Ed",
    "Ne",
    "Et",
    "Jó",
    "Sl",
    "Pv",
    "Ec",
    "Ct",
    "Is",
    "Jr",
    "Lm",
    "Ez",
    "Dn",
    "Os",
    "Jl",
    "Am",
    "Ob",
    "Jn",
    "Mq",
    "Na",
    "Hc",
    "Sf",
    "Ag",
    "Zc",
    "Ml",
    "Mt",
    "Mc",
    "Lc",
    "Jo",
    "At",
    "Rm",
    "1Co",
    "2Co",
    "Gl",
    "Ef",
    "Fp",
    "Cl",
    "1Ts",
    "2Ts",
    "1Tm",
    "2Tm",
    "Tt",
    "Fm",
    "Hb",
    "Tg",
    "1Pe",
    "2Pe",
    "1Jo",
    "2Jo",
    "3Jo",
    "Jd",
    "Ap"
  ];
  String mKey = "${DateTime.now().year}-${DateTime.now().month}";
  bool _markedRead = false;
  String today = DateFormat('yyyy-MM-dd').format(DateTime.now());
  late ConfettiController _confettiController;

  @override
  void initState() {
    super.initState();
    _confettiController =
        ConfettiController(duration: const Duration(seconds: 3));
    _load();
    if (DateTime.now().day == 1) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _showMonthEndDialog());
    }
    // Não carrega marcações aqui, pois _l e _c ainda não estão definidos
  }

  _load() async {
    final String res = await rootBundle.loadString('assets/data/biblia.json');
    setState(() => _livros = json.decode(res));
  }

  Color _cor(int index) {
    // Separação por cores conforme tipos de livros da Bíblia
    if (index <= 4) return Colors.blue; // Pentateuco
    if (index <= 16) return Colors.green; // Livros Históricos
    if (index <= 21) return Colors.orange; // Livros Poéticos
    if (index <= 26) return Colors.purple; // Profetas Maiores
    if (index <= 38) return Colors.red; // Profetas Menores
    if (index <= 42) return Colors.teal; // Evangelhos
    if (index == 43) return Colors.cyan; // Atos
    if (index <= 56) return Colors.indigo; // Epístolas Paulinas
    if (index <= 64) return Colors.pink; // Epístolas Gerais
    return Colors.amber; // Apocalipse
  }

  Future<void> _handleStartReading() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;
    final docRef =
        FirebaseFirestore.instance.collection('ranking').doc("${u.uid}_$mKey");
    final doc = await docRef.get();
    final data = doc.data() ?? {};
    final lastDay = data['lastAccessDay'] as String?;
    if (lastDay != today) {
      await docRef.set({
        'nome': u.email!.split('@')[0],
        'pontos': FieldValue.increment(0),
        'daysAccessed': FieldValue.increment(1),
        'totalPoints': FieldValue.increment(3),
        'month': mKey,
        'lastAccessDay': today,
      }, SetOptions(merge: true));
    }
  }

  void _showMonthEndDialog() {
    final prevMonth = DateTime.now().subtract(const Duration(days: 1));
    final prevMKey = "${prevMonth.year}-${prevMonth.month}";
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("🏆 Fim do Desafio Mensal!"),
        content: SizedBox(
          height: 400,
          width: 300,
          child: Stack(
            children: [
              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('ranking')
                    .where('month', isEqualTo: prevMKey)
                    .orderBy('totalPoints', descending: true)
                    .limit(10)
                    .snapshots(),
                builder: (c, snap) {
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return ListView(
                    children: snap.data!.docs.asMap().entries.map((entry) {
                      final d = entry.value;
                      final rank = entry.key + 1;
                      String medal = "";
                      if (rank == 1) {
                        medal = "🥇";
                      } else if (rank == 2)
                        medal = "🥈";
                      else if (rank == 3) medal = "🥉";
                      return ListTile(
                        leading: Text("$medal #$rank"),
                        title: Text(d['nome']),
                        trailing: Text("${d['totalPoints']} XP"),
                      );
                    }).toList(),
                  );
                },
              ),
              Align(
                alignment: Alignment.topCenter,
                child: ConfettiWidget(
                  confettiController: _confettiController,
                  blastDirectionality: BlastDirectionality.explosive,
                  shouldLoop: false,
                  colors: [Colors.amber, Colors.blue, Colors.green, Colors.red],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Fechar")),
        ],
      ),
    );
    _confettiController.play();
  }

  @override
  void dispose() {
    _confettiController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_livros.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(_l == null ? "Bíblia" : "${_l!['name']} ${_c ?? ''}"),
        backgroundColor: Colors.transparent,
        leading: _l != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  widget.onReading(false);
                  setState(() {
                    if (_c != null) {
                      _c = null;
                    } else {
                      _l = null;
                    }
                  });
                })
            : null,
        actions: _l == null
            ? [
                IconButton(
                  icon: const Icon(Icons.emoji_events, color: Colors.amber),
                  tooltip: 'Desafio Mensal',
                  onPressed: _showRankingDialog,
                ),
              ]
            : null,
      ),
      body: _l == null
          ? _buildHome()
          : (_c == null ? _buildCaps() : _buildRead()),
    );
  }

  Widget _buildRead() {
    final chapter = _l!['chapters'][_c! - 1];
    // Carrega marcações persistidas ao abrir capítulo
    return FutureBuilder<void>(
      future: _loadMarcados(),
      builder: (context, snap) {
        return Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ListView.builder(
                  itemCount: chapter.length,
                  itemBuilder: (context, i) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6.0),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _showVerseOptions(
                            context, i + 1, chapter[i],
                            index: i),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              vertical: 8, horizontal: 6),
                          decoration: BoxDecoration(
                            color: _versiculosMarcados.contains(i)
                                ? const Color(0xFFFFFF00).withOpacity(0.6)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${i + 1} ',
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: Colors.amber,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  chapter[i],
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                                    IconButton(
                      icon: const Icon(Icons.chevron_left),
                      onPressed: () {
                        if (_c! > 1) {
                          setState(() {
                            _c = _c! - 1;
                            _markedRead = false; // Reset temporário enquanto carrega
                          });
                          _loadMarcados();
                        }
                      }),
                  ElevatedButton(
                      onPressed: _markedRead
                          ? null
                          : () async {
                              final u = FirebaseAuth.instance.currentUser;
                              if (u != null) {
                                final docRef = FirebaseFirestore.instance
                                    .collection('ranking')
                                    .doc("${u.uid}_$mKey");
                                final doc = await docRef.get();
                                final data = doc.data() ?? {};
                                final lastDay =
                                    data['lastAccessDay'] as String?;
                                if (lastDay != today) {
                                  await docRef.set({
                                    'nome': u.email!.split('@')[0],
                                    'pontos': FieldValue.increment(0),
                                    'daysAccessed': FieldValue.increment(1),
                                    'totalPoints': FieldValue.increment(3),
                                    'month': mKey,
                                    'lastAccessDay': today,
                                  }, SetOptions(merge: true));
                                }
                              }
                              setState(() => _markedRead = true);
                              await _saveMarcados();
                            },
                      style: ElevatedButton.styleFrom(
                          backgroundColor: _markedRead
                              ? Colors.green
                              : Colors.grey.withOpacity(0.5)),
                      child: Text(_markedRead ? "LIDO ✅" : "MARCAR LIDO")),
                  IconButton(
                      icon: const Icon(Icons.chevron_right),
                      onPressed: () {
                        if (_c! < _l!['chapters'].length) {
                          setState(() {
                            _c = _c! + 1;
                            _markedRead = false; // Reset temporário enquanto carrega
                          });
                          _loadMarcados();
                        }
                      }),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
        );
      },
    );
  }

  void _showVerseOptions(BuildContext context, int numero, String texto,
      {int? index}) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('Copiar versículo'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: '$numero $texto'));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Versículo copiado!')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.check),
            title: const Text('Marcar versículo'),
            onTap: () async {
              if (index != null) {
                setState(() {
                  if (_versiculosMarcados.contains(index)) {
                    _versiculosMarcados.remove(index);
                  } else {
                    _versiculosMarcados.add(index);
                  }
                });
                await _saveMarcados();
              }
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_versiculosMarcados.contains(index)
                      ? 'Versículo marcado!'
                      : 'Versículo desmarcado!'),
                  backgroundColor: Colors.yellow[700],
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

    Future<void> _saveMarcados() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _marcadosKey, _versiculosMarcados.map((e) => e.toString()).toList());
    
    // Salva também o status de capítulo lido
    if (_l != null && _c != null) {
      await prefs.setBool('read_${_l!['name']}_$_c', _markedRead);
    }
  }

  Future<void> _loadMarcados() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Carrega versículos marcados
    final marcados = prefs.getStringList(_marcadosKey) ?? [];
    final marcadosSet =
        marcados.map((e) => int.tryParse(e)).whereType<int>().toSet();
    
    // Carrega status de capítulo lido
    bool isChapterRead = false;
    if (_l != null && _c != null) {
      isChapterRead = prefs.getBool('read_${_l!['name']}_$_c') ?? false;
    }

    if (!setEquals(marcadosSet, _versiculosMarcados) || isChapterRead != _markedRead) {
      setState(() {
        _versiculosMarcados = marcadosSet;
        _markedRead = isChapterRead;
      });
    }
  }

  void _showRankingDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("🏆 Ranking do Mês"),
        content: SizedBox(
          height: 400,
          width: 300,
          child: Stack(
            children: [
              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('ranking')
                    .where('month', isEqualTo: mKey)
                    .orderBy('totalPoints', descending: true)
                    .limit(10)
                    .snapshots(),
                builder: (c, snap) {
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return ListView(
                    children: snap.data!.docs.asMap().entries.map((entry) {
                      final d = entry.value;
                      final rank = entry.key + 1;
                      String medal = "";
                      if (rank == 1) {
                        medal = "🥇";
                      } else if (rank == 2)
                        medal = "🥈";
                      else if (rank == 3) medal = "🥉";
                      return ListTile(
                        leading: Text("$medal #$rank"),
                        title: Text(d['nome']),
                        trailing: Text("${d['totalPoints']} XP"),
                      );
                    }).toList(),
                  );
                },
              ),
              Align(
                alignment: Alignment.topCenter,
                child: ConfettiWidget(
                  confettiController: _confettiController,
                  blastDirectionality: BlastDirectionality.explosive,
                  shouldLoop: false,
                  colors: [Colors.amber, Colors.blue, Colors.green, Colors.red],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Fechar"),
          ),
        ],
      ),
    );
    _confettiController.play();
  }

  Widget _buildCaps() => GridView.builder(
      padding: const EdgeInsets.all(25),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5, mainAxisSpacing: 10, crossAxisSpacing: 10),
      itemCount: _l!['chapters'].length,
      itemBuilder: (c, i) => InkWell(
          onTap: () async {
            await _handleStartReading();
            setState(() {
              _c = i + 1;
              _markedRead = false;
            });
            widget.onReading(true);
          },
          child: Container(
              decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(10)),
              child: Center(
                  child: Text("${i + 1}",
                      style: const TextStyle(color: Colors.white))))));

  // Removido _buildRead duplicado para evitar conflito de nome

// Widget customizado para versículos da Bíblia
}

class VersiculoWidget extends StatelessWidget {
  final String texto;
  const VersiculoWidget({super.key, required this.texto});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.white10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          texto,
          style: const TextStyle(
            fontSize: 16,
            color: Colors.white,
            fontStyle: FontStyle.italic,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// --- 6. ÁREA DO MEMBRO ---
class AbaMembroFull extends StatefulWidget {
  const AbaMembroFull({super.key});

  @override
  State<AbaMembroFull> createState() => _AbaMembroFullState();
}

class _AbaMembroFullState extends State<AbaMembroFull> {
  Future<bool> _isOperator(String email) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('operadores')
          .doc(email)
          .get();
      return doc.exists;
    } catch (e) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        final user = snapshot.data;
        if (user == null) {
          return Scaffold(
            body: Center(
              child: _GlassCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock, size: 40, color: Colors.amber),
                    const SizedBox(height: 20),
                    const Text('Área do membro',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: () => signInWithGoogle(context),
                      child: const Text('Login Google'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
              title: const Text('Área do Membro'),
              backgroundColor: Colors.transparent,
              leading: null,
              actions: [
                IconButton(
                  icon: const Icon(Icons.settings, color: Colors.white70),
                  tooltip: 'Configurações',
                  onPressed: () => _showConfigModal(context, user),
                ),
              ]),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 160),
            children: [
              _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        'Olá, ${user.displayName ?? user.email?.split('@').first ?? 'Membro'}',
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
                    const SizedBox(height: 8),
                    Text(user.email ?? '',
                        style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
              _item(
                  'Relatório de Célula',
                  Icons.assignment,
                  () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (c) => const TelaFormRelatorio()))),
              _item(
                  'Volts',
                  Icons.flash_on,
                  () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (c) => const TelaCadastroMembro()))),
                // Item 'Inscrições' removido da área do membro — manter apenas na Agenda
              _item(
                  'Minhas Anotações',
                  Icons.sticky_note_2,
                  () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (c) => const TelaMinhasAnotacoes()))),
              FutureBuilder<bool>(
                future: _isOperator(user.email ?? ''),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const SizedBox.shrink();
                  }
                  if (snap.hasData && snap.data == true) {
                    return _expansion('Acesso Restrito', Icons.security, [
                      _sub(
                          'Check-in/Check-out',
                          () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (c) => const TelaCheckInOut()))),
                      _sub(
                        'Relatório Culto',
                        () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (c) => const TelaRelatorioCulto()),
                        ),
                      ),
                                            _sub(
                        'Relatório DIFLEN',
                        () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (c) => const TelaRelatorioDiflen()),
                        ),
                      ),
                      _sub(
                        'Checklist do Culto',
                        () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (c) => const TelaChecklistCulto()),
                        ),
                      ),
                    ]);
                  } else {
                    return _item('Acesso Restrito', Icons.security, () {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Acesso não autorizado'),
                          content: const Text(
                              'Você não tem permissão para acessar esta área.'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('OK'),
                            ),
                          ],
                        ),
                      );
                    });
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showConfigModal(BuildContext context, User user) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1a1a2e),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text('Configurações',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ListTile(
              leading:
                  const Icon(Icons.privacy_tip_outlined, color: Colors.white70),
              title: const Text('Política de Privacidade',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                launchUrl(
                    Uri.parse(
                        'https://pazcastanhal-809cd.web.app/privacy_policy.html'),
                    mode: LaunchMode.externalApplication);
              },
            ),
            const Divider(color: Colors.white12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text('Minha Conta',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            ),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.white70),
              title: const Text('Sair', style: TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(context);
                await GoogleSignIn().signOut();
                await FirebaseAuth.instance.signOut();
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.delete_forever, color: Colors.redAccent),
              title: const Text('Apagar minha conta',
                  style: TextStyle(color: Colors.redAccent)),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteAccount(context, user);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteAccount(BuildContext context, User user) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apagar conta'),
        content: const Text(
            'Isso irá apagar permanentemente suas anotações e remover seu acesso. Esta ação não pode ser desfeita.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(ctx);
              await _deleteAccount(context, user);
            },
            child: const Text('Apagar'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteAccount(BuildContext context, User user) async {
    try {
      final uid = user.uid;
      final db = FirebaseFirestore.instance;

      // Deletar anotações do usuário
      final notes = await db
          .collection('user_notes')
          .where('userId', isEqualTo: uid)
          .get();
      for (final doc in notes.docs) {
        await doc.reference.delete();
      }

      // Deletar documento do usuário
      await db.collection('usuarios').doc(uid).delete();

      // Deletar conta no Firebase Auth
      await user.delete();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Conta apagada com sucesso.')));
      }
    } on FirebaseAuthException catch (e) {
      if (e.code == 'requires-recent-login') {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Por segurança, faça login novamente antes de apagar a conta.')));
          await FirebaseAuth.instance.signOut();
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Erro ao apagar conta: ${e.message}')));
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erro: $e')));
      }
    }
  }

  Widget _item(String t, IconData i, VoidCallback tap) => _GlassCard(
      child: ListTile(
          leading: Icon(i, color: Colors.blueAccent),
          title: Text(t, style: const TextStyle(color: Colors.white)),
          onTap: tap));
  Widget _expansion(String t, IconData i, List<Widget> c) => _GlassCard(
      child: ExpansionTile(
          leading: Icon(i, color: Colors.amber),
          title: Text(t, style: const TextStyle(color: Colors.white)),
          children: c));
  Widget _sub(String t, [VoidCallback? tap]) => ListTile(
      title:
          Text(t, style: const TextStyle(fontSize: 14, color: Colors.white70)),
      trailing: const Icon(Icons.chevron_right, size: 14),
      onTap: tap);
}

// --- 7. HUB CÉLULA & LEITURA ---
class TelaHubCelula extends StatelessWidget {
  const TelaHubCelula({super.key});

  static const _backgroundTop = Color(0xFF10213C);
  static const _backgroundBottom = Color(0xFF050B16);

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: _backgroundBottom,
      appBar: AppBar(
          title: const Text("Célula"), backgroundColor: Colors.transparent),
      body: Container(
          decoration: const BoxDecoration(
              gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [_backgroundTop, _backgroundBottom])),
          child: Stack(children: [
            Positioned(
                top: -80,
                right: -40,
                child: _GlowOrb(
                    color: Colors.blueAccent.withAlpha(35), size: 220)),
            Positioned(
                left: -70,
                bottom: 60,
                child: _GlowOrb(
                    color: Colors.tealAccent.withAlpha(22), size: 200)),
            SafeArea(
                child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                    child: Column(children: [
                      Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(22),
                          decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(24),
                              gradient: LinearGradient(colors: [
                                Colors.white.withAlpha(20),
                                Colors.white.withAlpha(6)
                              ]),
                              border: Border.all(
                                  color: Colors.white.withAlpha(18))),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: const [
                                Text('Conteúdos para a sua célula',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 22,
                                        fontWeight: FontWeight.w700)),
                                SizedBox(height: 8),
                                Text(
                                    'Escolha estudos, materiais de crescimento e dinâmicas com uma apresentação mais limpa e objetiva.',
                                    style: TextStyle(
                                        color: Colors.white70,
                                        height: 1.4,
                                        fontSize: 13))
                              ])),
                      const SizedBox(height: 18),
                      Expanded(
                          child: GridView.count(
                              crossAxisCount: 2,
                              mainAxisSpacing: 14,
                              crossAxisSpacing: 14,
                              childAspectRatio: 0.86,
                              children: [
                            _it(context, "Estudo", Icons.book_outlined,
                                const Color(0xFF4DA3FF), "Estudo"),
                                                        _it(
                                context,
                                "Dicas para Líderes",
                                Icons.trending_up_rounded,
                                const Color(0xFF3DDC97),
                                "Crescimento"),
                            _it(
                                context,
                                "Dinâmicas",
                                Icons.auto_fix_high_rounded,
                                const Color(0xFFFFA84D),
                                "Dinâmicas"),
                            _it(
                                context,
                                "Quero uma Célula",
                                Icons.chat_bubble_outline_rounded,
                                const Color(0xFF4DD0E1),
                                "",
                                isWa: true),
                          ]))
                    ])))
          ])));

  Widget _it(BuildContext context, String l, IconData i, Color c, String id,
          {bool isWa = false}) =>
      _GlassCard(
          padding: EdgeInsets.zero,
          radius: 26,
          child: Material(
              color: Colors.transparent,
              child: InkWell(
                  borderRadius: BorderRadius.circular(26),
                  onTap: () {
                    if (isWa) {
                      launchUrl(Uri.parse("https://wa.me/5591988629296"));
                    } else if (l == "Estudo") {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (c) =>
                                  TelaListaDoc(coll: 'estudos', title: l)));
                                        } else if (l == "Dinâmicas") {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (c) =>
                                  TelaListaDoc(coll: 'dinamicas', title: l)));
                    } else if (l == "Dicas para Líderes") {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (c) =>
                                  TelaListaDoc(coll: 'crescimento', title: l)));
                    } else {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (c) => TelaListaDoc(
                                  coll: 'celula_conteudo', title: l)));
                    }
                  },
                  child: Ink(
                      decoration: BoxDecoration(
                          gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                c.withAlpha(42),
                                Colors.white.withAlpha(10)
                              ]),
                          borderRadius: BorderRadius.circular(26),
                          border: Border.all(color: c.withAlpha(65))),
                      child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                    height: 50,
                                    width: 50,
                                    decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: c.withAlpha(28),
                                        border: Border.all(
                                            color: c.withAlpha(90),
                                            width: 1.2)),
                                    child: Icon(i, color: c, size: 24)),
                                const Spacer(),
                                Text(l,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 17,
                                        height: 1.2,
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700)),
                                const SizedBox(height: 6),
                                Text(
                                    isWa
                                        ? 'Fale com a equipe'
                                        : 'Abrir coleção',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.white.withAlpha(165))),
                                const SizedBox(height: 14),
                                Row(children: [
                                  Text(isWa ? 'Conversar' : 'Explorar agora',
                                      style: TextStyle(
                                          color: c,
                                          fontWeight: FontWeight.w600)),
                                  const Spacer(),
                                  Icon(Icons.arrow_forward_rounded,
                                      color: c, size: 18)
                                ])
                              ]))))));
}

class TelaLeituraDoc extends StatefulWidget {
  final String id;
  final String title;
  final String coll;
  const TelaLeituraDoc(
      {super.key, required this.id, required this.title, required this.coll});
  @override
  State<TelaLeituraDoc> createState() => _TelaLeituraDocState();
}

class _TelaLeituraDocState extends State<TelaLeituraDoc> {
  // Botão de teste para adicionar/remover like manualmente
  void _testLikeFirestore() async {
    final userId = FirebaseAuth.instance.currentUser?.uid ?? 'teste_user';
    try {
      final doc = await _docRef.get();
      final data = doc.data() as Map<String, dynamic>? ?? {};
      final likes = data.containsKey('likes') && data['likes'] is List
          ? List<String>.from(data['likes'])
          : <String>[];
      if (likes.contains(userId)) {
        likes.remove(userId);
        print('Removendo like para $userId');
      } else {
        likes.add(userId);
        print('Adicionando like para $userId');
      }
      await _docRef.update({'likes': likes});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Like atualizado com sucesso!')),
        );
      }
    } catch (e) {
      print('Erro no teste de like: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao testar like: $e')),
        );
      }
    }
  }

  final Color _bgColor = const Color(0xFF0F2C59);
  final Color _textColor = Colors.white;
  final double _fontSize = 16;
  late CollectionReference _colRef;
  late DocumentReference _docRef;

  @override
  void initState() {
    super.initState();
    _colRef = FirebaseFirestore.instance.collection(widget.coll);
    _docRef = _colRef.doc(widget.id);
  }

  Future<void> _toggleLike() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Faça login para curtir')));
      return;
    }
    try {
      final doc = await _docRef.get();
      final likes = List<String>.from(doc['likes'] ?? []);
      if (likes.contains(userId)) {
        await _docRef.update({
          'likes': FieldValue.arrayRemove([userId])
        });
      } else {
        await _docRef.update({
          'likes': FieldValue.arrayUnion([userId])
        });
      }
    } catch (e) {
      print('Erro ao curtir: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Erro ao curtir documento')),
      );
    }
  }

    Widget _buildReportDetail(Map data) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _reportField('Data', data['data']),
        _reportField('Líder', data['lider']),
        _reportField('Membros Presentes', data['membros_presentes']?.toString()),
        _reportField('Convidados', data['convidados']?.toString()),
        _reportField('Crianças', data['criancas']?.toString()),
        _reportField('Ofertas', 'R\$ ${data['ofertas']?.toString() ?? '0.00'}'),
        _reportField('Supervisão', (data['supervisao'] == true) ? 'Sim' : 'Não'),
        _reportField('Observações', data['observacoes']),
      ],
    );
  }

    Widget _reportField(String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.amber,
                  fontWeight: FontWeight.bold,
                  fontSize: 12)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(color: Colors.white, fontSize: 16)),
          const Divider(color: Colors.white10),
        ],
      ),
    );
  }

  Widget _buildGuiaEstudoCard(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [Colors.amber.withOpacity(0.2), Colors.amber.withOpacity(0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.amber.withOpacity(0.3)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _showGuiaEstudoModal(context),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.auto_awesome, color: Colors.amber, size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'Como guiar o Estudo?',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        'Dicas práticas para a discussão.',
                        style: TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_ios, color: Colors.amber, size: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }

    void _showGuiaEstudoModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.85,
        decoration: const BoxDecoration(
          color: Color(0xFF0F2C59),
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 20),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                children: [
                  const Center(
                    child: Text(
                      'COMO CONDUZIR ESTE MOMENTO',
                      style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, letterSpacing: 1.5, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 30),
                  
                  _guiaItem(
                    '1', 
                    'NÃO PREGUE NEM ENSINE!', 
                    'O maior erro cometido por aqueles que ministram a palavra na célula é tentar pregar novamente a mensagem de domingo. Não atue como um pregador ou professor, pois se tentar fazê-lo, tenderá a monopolizar a discussão. Na verdade, se você tentar pregar novamente a mensagem, fará com que a reunião da célula seja um monótono monólogo, no qual apenas você falará.'
                  ),
                  
                  _guiaItem(
                    '2', 
                    'ENVOLVA SEM CONSTRANGER!', 
                    'Você sempre acertará o centro do alvo quando mirar na coisa certa: envolver todos na reconstrução e discussão da mensagem de domingo. Peça para um membro fazer uma dinâmica inicial, peça para outro ler o texto bíblico, indique outro para ler as perguntas e estimule todos a responderem às perguntas. Entretanto, faça isso sem constranger as pessoas.'
                  ),

                  _guiaItem(
                    '3', 
                    'FACILITE!', 
                    'Tudo começa com esta imagem mental correta: você é um facilitador de uma discussão sobre a mensagem de domingo, e não um professor que a explicará ou um pregador que a proclamará. O seu papel é facilitar a discussão, mantendo-a dentro do tema da mensagem.'
                  ),

                  _guiaItem(
                    '4', 
                    'GUIE A DISCUSSÃO!', 
                    'Já faz algum tempo que não utilizamos mais o termo estudo da célula. Em vez disso, usamos o nome mais correto: guia de discussão! Sei que pode parecer um mero detalhe, mas o fato é que os nomes, na Bíblia, revelam a essência das coisas e das pessoas. Portanto, a essência da palavra na célula não é dar um estudo, mas simplesmente guiar e facilitar uma discussão sobre a mensagem de domingo.'
                  ),
                  
                  const SizedBox(height: 50),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _guiaItem(String numero, String titulo, String texto) {
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.amber,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  numero,
                  style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  titulo,
                  style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.w900, fontSize: 15, letterSpacing: 0.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.only(left: 40),
            child: Text(
              texto,
              style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.5, fontWeight: FontWeight.w400),
              textAlign: TextAlign.justify,
            ),
          ),
          const SizedBox(height: 16),
          const Divider(color: Colors.white10),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          // Exibe apenas o nome da tela (widget.title), nunca o título do texto
          title: Text(widget.title),
        ),

                body: StreamBuilder<DocumentSnapshot>(
                  stream: _docRef.snapshots(),
                  builder: (context, snap) {
                    Map data = snap.data?.data() as Map? ?? {};
            final userId = FirebaseAuth.instance.currentUser?.uid;
            final likes = List<String>.from(data['likes'] ?? []);
            final isLiked = userId != null && likes.contains(userId);
            final preletor = data['preletor']?.toString() ?? '';
                        return Container(
              color: _bgColor,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  // CARD: Como guiar o estudo? (Apenas se for coleção de estudos)
                  if (widget.coll == 'estudos') ...[
                    _buildGuiaEstudoCard(context),
                    const SizedBox(height: 24),
                  ],
                  // Título do texto (exibe apenas no corpo)
                  if ((data['titulo']?.toString().isNotEmpty ?? false))
                    Text(
                      data['titulo'].toString(),
                      style: TextStyle(
                        color: Colors.amber,
                        fontWeight: FontWeight.bold,
                        fontSize: _fontSize + 8,
                        letterSpacing: 1.2,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  if (preletor.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Por $preletor',
                      style: TextStyle(
                        color: _textColor,
                        fontSize: _fontSize - 2,
                        fontStyle: FontStyle.italic,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                                    // Conteúdo principal
                  if (widget.coll == 'relatorios_celula')
                    _buildReportDetail(data)
                  else
                    Builder(builder: (context) {

                                        final texto = data['texto'] ?? data['conteudo'] ?? data['conteudo_html'] ?? '';
                    String plainTexto = '';
                    Widget contentWidget;
                    if (texto is String && texto.trim().startsWith('<') &&
                        texto.trim().endsWith('>')) {
                      // Provável HTML
                      // Melhora a limpeza do HTML para cópia
                      plainTexto = texto
                          .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
                          .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n\n')
                          .replaceAll(RegExp(r'<[^>]*>'), '')
                          .replaceAll('&quot;', '"')
                          .replaceAll('&amp;', '&')
                          .replaceAll('&lt;', '<')
                          .replaceAll('&gt;', '>')
                          .replaceAll('&nbsp;', ' ')
                          .replaceAll('&#39;', "'");
                      
                      contentWidget = HtmlWidget(
                        texto,
                        textStyle:
                            TextStyle(color: _textColor, fontSize: _fontSize),
                      );
                    } else {
                      // Tenta Quill ou texto puro
                      try {
                        final quillDoc = quill.Document.fromJson(jsonDecode(texto));
                        plainTexto = quillDoc.toPlainText();
                        final controller = quill.QuillController(
                          document: quillDoc,
                          selection: const TextSelection.collapsed(offset: 0),
                          readOnly: true,
                        );
                        contentWidget = quill.QuillEditor.basic(
                          controller: controller,
                          config: quill.QuillEditorConfig(
                            enableInteractiveSelection: true,
                          ),
                        );
                      } catch (_) {
                        plainTexto = texto.toString();
                        contentWidget = Text(
                          texto.toString(),
                          style: TextStyle(color: _textColor, fontSize: _fontSize),
                        );
                      }
                    }
                    // Exibe o conteúdo envolto em SelectionArea para permitir seleção nativa
                    Widget display = SelectionArea(child: contentWidget);
                                        // Botões de ação: compartilhar e copiar (visíveis para estudos/célula e outros, exceto relatórios)
                    return Column(children: [
                      display,
                      if (widget.coll != 'relatorios_celula') ...[
                        const SizedBox(height: 12),
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          IconButton(
                            icon: const Icon(Icons.share, color: Colors.white),
                            onPressed: () {
                              final shareTitle = data['titulo']?.toString() ?? widget.title;
                              Share.share('$shareTitle\n\n$plainTexto');
                            },
                            tooltip: 'Compartilhar',
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.copy, color: Colors.white),
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: plainTexto));
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Texto formatado copiado!')));
                              }
                            },
                            tooltip: 'Copiar',
                          )
                        ]),
                      ]
                    ]);

                  }),
                  const SizedBox(height: 24),
                  // Likes e ações (apenas para devocionais)
                  if (widget.coll == 'devocionais')
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: Icon(
                              isLiked ? Icons.favorite : Icons.favorite_border,
                              color: Colors.red,
                              size: 20),
                          onPressed: _toggleLike,
                          tooltip: isLiked ? 'Descurtir' : 'Curtir',
                        ),
                        const SizedBox(width: 8),
                        Text(
                          likes.length.toString(),
                          style: const TextStyle(
                              color: Colors.red, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                ],
              ),
            );
          },
        ),
      );
}

// --- 8. LOJA PAZ ---
class TelaLoja extends StatelessWidget {
  const TelaLoja({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text("Paz Store")),
      body: SingleChildScrollView(
          padding: const EdgeInsets.all(10),
          child: Column(children: [
            _AdsBanner(
                title: "Livros do Pr. Francinaldo",
                url: "https://share.google/To7MjnzASZFSbiNDE"),
            const SizedBox(height: 15),
            GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.7,
                children: [
                  _p(context, "Livro do Discípulo", "R\$ 25,00",
                      "https://dcdn-us.mitiendanube.com/stores/007/416/970/products/40bd3e1a0bd0dfb0a8275d03bc3f327d-0c85bc734dab8997a517762053408268-1024-1024.png"),
                  _p(context, "Camisa VOLTS", "R\$ 40,00",
                      "https://i.ibb.co/7NjwCDKC/ff1553b7-c13e-4992-9952-679808fa127d.jpg"),
                ]),
          ])));
  Widget _p(context, t, p, img) => _GlassCard(
          child: Column(children: [
        Expanded(
            child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: _networkImage(img, fit: BoxFit.cover))),
        Text(t,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.white)),
        Text(p, style: const TextStyle(color: Colors.amber)),
        ElevatedButton(
            onPressed: () => launchUrl(Uri.parse(
                "https://wa.me/5591988629296?text=Olá, quero comprar o $t")),
            child: const Text("COMPRAR", style: TextStyle(fontSize: 10)))
      ]));
}

// --- DEMAIS TELAS ---
class TelaCheckInOut extends StatefulWidget {
  const TelaCheckInOut({super.key});

  @override
  State<TelaCheckInOut> createState() => _TelaCheckInOutState();
}

class _TelaCheckInOutState extends State<TelaCheckInOut> {
  String _scannedCode = '';
  bool _isProcessing = false;
  Map<String, dynamic>? _memberData;
  bool _isCheckIn = true; // true = check-in, false = check-out
    Map<String, bool> _selectedItems = {
    'cracha': false,
    'cordao': false,
    'equipamento': false,
  };

  @override
  void initState() {
    super.initState();
  }

  Future<void> _scanQR() async {

    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
    });
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const QRScannerScreen()),
    );

    if (result != null && result is String) {
      setState(() {
        _scannedCode = result;
      });
      await _processScan(result);
    } else {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _processScan(String qrCode) async {
    try {
      // Buscar dados do membro no Firestore
      final memberDoc = await FirebaseFirestore.instance
          .collection('usuarios')
          .doc(qrCode)
          .get();

      if (!memberDoc.exists) {
        throw Exception('Membro não encontrado');
      }

      final memberData = memberDoc.data()!;
      setState(() {
        _memberData = memberData;
      });

      // Verificar se já fez check-in hoje
      final today = DateTime.now();
      final startOfDay = DateTime(today.year, today.month, today.day);
      final endOfDay = startOfDay.add(const Duration(days: 1));

            final existingCheckin = await FirebaseFirestore.instance
          .collection('volts_checkin')
          .where('user_id', isEqualTo: qrCode)
          .where('situacao', isEqualTo: 'Em uso')
          .where('timestamp',
              isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
          .where('timestamp', isLessThan: Timestamp.fromDate(endOfDay))
          .limit(1)
          .get();

      if (existingCheckin.docs.isNotEmpty) {
        // Já fez check-in hoje, perguntar se quer fazer check-out
        final checkinData = existingCheckin.docs.first.data();
        final checkedItems =
            checkinData['itens'] as Map<String, dynamic>? ?? {};
        setState(() {
          _isCheckIn = false;
          _selectedItems = {
            'cracha': checkedItems['cracha'] == true,
            'cordao': checkedItems['cordao'] == true,
            'equipamento': checkedItems['equipamento'] == true,
          };
        });

        if (context.mounted) {
          final shouldCheckout = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Check-out'),
              content: Text(
                  'Membro ${memberData['nome']} já fez check-in hoje. Deseja fazer check-out?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancelar'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Check-out'),
                ),
              ],
            ),
          );

          if (shouldCheckout == true) {
          await _showCheckoutDialog(
              existingCheckin.docs.first.id, checkinData);
          // Limpa o estado após checkout bem-sucedido
          setState(() {
            _memberData = null;
            _scannedCode = '';
            _selectedItems = {
              'cracha': false,
              'cordao': false,
              'equipamento': false,
            };
          });
          }
        }
      } else {
        // Primeiro check-in do dia
        setState(() {
          _isCheckIn = true;
          _selectedItems = {
            'cracha': false,
            'cordao': false,
            'equipamento': false
          };
        });
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e')),
        );
      }
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _showCheckoutDialog(
      String docId, Map<String, dynamic> checkinData) async {
    final checkedItems = checkinData['itens'] as Map<String, dynamic>? ?? {};
    Map<String, bool> returnedItems = {
      'cracha': false,
      'cordao': false,
      'equipamento': false,
    };

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Check-out: ${_memberData?['nome']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Itens à devolver:',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              if (checkedItems['cracha'] == true)
                CheckboxListTile(
                  title: const Text('Crachá'),
                  value: returnedItems['cracha'],
                  onChanged: (value) =>
                      setState(() => returnedItems['cracha'] = value ?? false),
                ),
              if (checkedItems['cordao'] == true)
                CheckboxListTile(
                  title: const Text('Cordão'),
                  value: returnedItems['cordao'],
                  onChanged: (value) =>
                      setState(() => returnedItems['cordao'] = value ?? false),
                ),
              if (checkedItems['equipamento'] == true)
                CheckboxListTile(
                  title: const Text('Equipamento'),
                  value: returnedItems['equipamento'],
                  onChanged: (value) => setState(
                      () => returnedItems['equipamento'] = value ?? false),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () async {
                await _performCheckout(docId, returnedItems);
                Navigator.pop(context);
              },
              child: const Text('Confirmar Check-out'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _performCheckout(
      String docId, Map<String, bool> returnedItems) async {
    try {
      // Atualizar no Firestore
      await FirebaseFirestore.instance
          .collection('volts_checkin')
          .doc(docId)
          .update({
        'situacao': 'Checkout OK',
        'checkout_timestamp': FieldValue.serverTimestamp(),
        'itens_devolvidos': returnedItems,
      });

      // Enviar para Google Sheets (timestamp correto)
      final now = DateTime.now();
      final checkoutData = {
        'user_id': _scannedCode,
        'nome': _memberData?['nome'],
        'ministerio': _memberData?['ministerio'],
        'itens': returnedItems,
        'situacao': 'Checkout OK',
        'tipo': 'checkout',
        'timestamp': {'seconds': now.millisecondsSinceEpoch ~/ 1000},
      };

      await _sendToGoogleSheets(checkoutData);

            if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Check-out realizado com sucesso!')),
        );
      }
    } catch (e) {

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro no check-out: $e')),
        );
      }
    }
  }

  Future<void> _performCheckin() async {
    if (_memberData == null) return;
    // Verificação de campos obrigatórios
    final nome = _memberData!['nome']?.toString().trim() ?? '';
    final ministerio = _memberData!['ministerio']?.toString().trim() ?? '';
    if (nome.isEmpty || ministerio.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Nome e Ministério do membro são obrigatórios para o check-in!'),
            backgroundColor: Colors.red,
          ),
        );
      }
      setState(() {
        _isProcessing = false;
      });
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      // Garante que todos os itens estejam presentes e sejam bool
      final itensToSave = {
        'cracha': _selectedItems['cracha'] == true,
        'cordao': _selectedItems['cordao'] == true,
        'equipamento': _selectedItems['equipamento'] == true,
      };

      // Timestamp para Firestore
      final firestoreData = {
        'user_id': _scannedCode,
        'nome': _memberData!['nome'],
        'ministerio': _memberData!['ministerio'],
        'itens': itensToSave,
        'situacao': 'Em uso',
        'timestamp': FieldValue.serverTimestamp(),
        'tipo': 'checkin',
      };

      // Timestamp para planilha (em segundos)
      final now = DateTime.now();
      final sheetData = {
        'user_id': _scannedCode,
        'nome': _memberData!['nome'],
        'ministerio': _memberData!['ministerio'],
        'itens': itensToSave,
        'situacao': 'Em uso',
        'timestamp': {'seconds': now.millisecondsSinceEpoch ~/ 1000},
        'tipo': 'checkin',
      };

      // Salvar no Firestore
      await FirebaseFirestore.instance
          .collection('volts_checkin')
          .add(firestoreData);

      // Enviar para Google Sheets
      await _sendToGoogleSheets(sheetData);

            if (context.mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Check-in Realizado'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 60),
                const SizedBox(height: 16),
                Text(
                    'Check-in realizado com sucesso para ${_memberData!['nome']}!'),
                const SizedBox(height: 8),
                const Text('Itens emprestados:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                if (itensToSave['cracha']!) const Text('• Crachá'),
                if (itensToSave['cordao']!) const Text('• Cordão'),
                if (itensToSave['equipamento']!) const Text('• Equipamento'),
              ],
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );

        setState(() {
          _memberData = null;
          _scannedCode = '';
          _selectedItems = {
            'cracha': false,
            'cordao': false,
            'equipamento': false
          };
          _isProcessing = false;
        });
      }
    } catch (e) {

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro no check-in: $e')),
        );
      }
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _sendToGoogleSheets(Map<String, dynamic> data) async {
    const String scriptUrl =
        'https://script.google.com/macros/s/AKfycbzWJQCSonQdd2k_xo7oUulLu1rmVBjwGZJ4ca9sT2a-12CjXm-hRqI9E6LC6C5P_HZMIg/exec';
    const String spreadsheetId =
        '1X4uB8ilDw-ZNSrr9rtBXNenmCRGNyrjCSQgcdSWIqhM'; // ID da planilha Volts
    try {
      final response = await http.post(
        Uri.parse(scriptUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'spreadsheetId': spreadsheetId,
          'sheetName': 'Volts',
          'data': data,
        }),
      );
      if (response.statusCode == 302) {
        debugPrint(
            'Aviso: resposta 302 recebida do Apps Script (redirecionamento).');
        return;
      }
      if (response.statusCode != 200) {
        throw Exception(
            'Erro ao enviar para planilha: [${response.statusCode}');
      }
      final responseData = jsonDecode(response.body);
      if (!responseData['success']) {
        throw Exception('Erro na planilha: [${responseData['error']}');
      }
    } catch (e) {
      debugPrint('Erro ao enviar para planilha Volts: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
        return Scaffold(
      appBar: AppBar(
        title: const Text('Check-in/Check-out'),
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.all(25),
        children: [
            // Scanner QR
            _GlassCard(
              child: Column(
                children: [
                  const Icon(Icons.qr_code_scanner,
                      size: 60, color: Colors.blueAccent),
                  const SizedBox(height: 20),
                  const Text(
                    'Escanear QR Code',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Aponte a câmera para o QR Code da identidade do membro',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _scanQR,
                    icon: const Icon(Icons.camera_alt),
                    label: Text(_isProcessing ? 'Processando...' : 'Escanear'),
                  ),
                ],
              ),
            ),

                        // Lista de check-ins ativos (Sempre visível abaixo do scanner)
            const SizedBox(height: 10),
            _GlassCard(
              child: ListaCheckinsAtivos(
                onCheckoutPressed: (docId, data) {
                  setState(() {
                    _memberData = data; // Carrega dados para o diálogo
                    _scannedCode = data['user_id'] ?? '';
                  });
                  _showCheckoutDialog(docId, data);
                },
              ),
            ),


            // Dados do membro escaneado
            if (_memberData != null) ...[
              const SizedBox(height: 20),
              _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isCheckIn ? 'Check-in' : 'Check-out',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Nome: ${_memberData!['nome'] ?? 'Não informado'}',
                      style: const TextStyle(color: Colors.white),
                    ),
                    Text(
                      'Ministério: ${_memberData!['ministerio'] ?? 'Não informado'}',
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 15),
                    Text(
                      _isCheckIn
                          ? 'Itens para empréstimo:'
                          : 'Itens à devolver:',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 10),
                    CheckboxListTile(
                      title: const Text('Crachá',
                          style: TextStyle(color: Colors.white)),
                      value: _selectedItems['cracha'],
                      onChanged: _isCheckIn
                          ? (value) => setState(
                              () => _selectedItems['cracha'] = value ?? false)
                          : null,
                      activeColor: Colors.amber,
                    ),
                    CheckboxListTile(
                      title: const Text('Cordão',
                          style: TextStyle(color: Colors.white)),
                      value: _selectedItems['cordao'],
                      onChanged: _isCheckIn
                          ? (value) => setState(
                              () => _selectedItems['cordao'] = value ?? false)
                          : null,
                      activeColor: Colors.amber,
                    ),
                    CheckboxListTile(
                      title: const Text('Equipamento'),
                      value: _selectedItems['equipamento'],
                      onChanged: _isCheckIn
                          ? (value) => setState(() =>
                              _selectedItems['equipamento'] = value ?? false)
                          : null,
                      activeColor: Colors.amber,
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isCheckIn ? _performCheckin : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              _isCheckIn ? Colors.green : Colors.blue,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: Text(_isCheckIn
                            ? 'Confirmar Check-in'
                            : 'Aguardando check-out...'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
        ],
      ),
    );
  }
}

class QRScannerScreen extends StatefulWidget {
  const QRScannerScreen({super.key});

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  bool _hasScanned = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanner QR'),
        backgroundColor: Colors.transparent,
      ),
      body: MobileScanner(
        onDetect: (capture) {
          if (_hasScanned) return;
          final List<Barcode> barcodes = capture.barcodes;
          for (final barcode in barcodes) {
            if (barcode.rawValue != null) {
              setState(() {
                _hasScanned = true;
              });
              Navigator.pop(context, barcode.rawValue);
              break;
            }
          }
        },
      ),
    );
  }
}

class TelaListaVideos extends StatelessWidget {
  const TelaListaVideos({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text("Mensagens")),
      body: StreamBuilder<QuerySnapshot>(
          stream:
              FirebaseFirestore.instance.collection('mensagens').snapshots(),
          builder: (c, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              padding: const EdgeInsets.all(25),
              children: snap.data!.docs
                  .map((v) => _VideoItem(
                        url: v['url'] ?? '',
                        titulo: v['titulo'] ?? '',
                      ))
                  .toList(),
            );
          }));
}

class _VideoItem extends StatefulWidget {
  final String url;
  final String titulo;
  const _VideoItem({required this.url, required this.titulo});

  @override
  State<_VideoItem> createState() => _VideoItemState();
}

class _VideoItemState extends State<_VideoItem> {
  late YoutubePlayerController _controller;
  String? _videoId;
  bool _loadVideo = false;

  @override
  void initState() {
    super.initState();
    _videoId = YoutubePlayerController.convertUrlToId(widget.url);
    
    _controller = YoutubePlayerController.fromVideoId(
      videoId: _videoId ?? '',
      autoPlay: false,
      params: const YoutubePlayerParams(
        showControls: true,
        showFullscreenButton: true,
        mute: false,
        showVideoAnnotations: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final thumbnailUrl = _videoId != null 
        ? 'https://img.youtube.com/vi/$_videoId/hqdefault.jpg' 
        : null;

    return _GlassCard(
      child: Column(
        children: [
          if (_videoId != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: _loadVideo 
                ? YoutubePlayer(
                    controller: _controller,
                    aspectRatio: 16 / 9,
                  )
                : InkWell(
                    onTap: () => setState(() => _loadVideo = true),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (thumbnailUrl != null)
                          _networkImage(
                            thumbnailUrl,
                            height: 200,
                            width: double.infinity,
                            fit: BoxFit.cover,
                          ),
                        Container(
                          height: 200,
                          width: double.infinity,
                          color: Colors.black26,
                        ),
                        const Icon(
                          Icons.play_circle_fill,
                          color: Colors.white,
                          size: 60,
                        ),
                      ],
                    ),
                  ),
            )
          else
            Container(
              height: 200,
              color: Colors.black12,
              alignment: Alignment.center,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
                  const SizedBox(height: 8),
                  const Text(
                    'Link do vídeo inválido.',
                    style: TextStyle(color: Colors.redAccent),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Text(
            widget.titulo,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          if (widget.url.isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                final uri = Uri.parse(widget.url);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Abrir no YouTube', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(foregroundColor: Colors.amber),
            ),
        ],
      ),
    );
  }
}


class TelaAvisosPro extends StatefulWidget {
  const TelaAvisosPro({super.key});

  @override
  State<TelaAvisosPro> createState() => _TelaAvisosProState();
}

class _TelaAvisosProState extends State<TelaAvisosPro> {
  List<String> _avisosExcluidos = [];
  DateTime? _dataInstalacao;

  @override
  void initState() {
    super.initState();
    _initInstalacaoEAvisos();
  }

  Future<void> _initInstalacaoEAvisos() async {
    final prefs = await SharedPreferences.getInstance();
    // Carrega/exibe avisos excluídos
    _avisosExcluidos = prefs.getStringList('avisosExcluidos') ?? [];
    // Carrega ou define a data de instalação
    String? dataStr = prefs.getString('dataInstalacao');
    if (dataStr == null) {
      final agora = DateTime.now();
      await prefs.setString('dataInstalacao', agora.toIso8601String());
      _dataInstalacao = agora;
    } else {
      _dataInstalacao = DateTime.tryParse(dataStr);
    }
    setState(() {});
  }

  // _loadAvisosExcluidos agora está embutido em _initInstalacaoEAvisos

  Future<void> _excluirAvisoLocal(String avisoId) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _avisosExcluidos.add(avisoId);
    });
    await prefs.setStringList('avisosExcluidos', _avisosExcluidos);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text("Mural")),
        body: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('avisos')
              .orderBy('data', descending: true)
              .snapshots(),
          builder: (c, snap) {
            // Se ainda não carregou a data de instalação, mostra loading
            if (_dataInstalacao == null) {
              return const Center(child: CircularProgressIndicator());
            }
            final docs = (snap.data?.docs ?? []).where((doc) {
              // Exclui avisos ocultados
              if (_avisosExcluidos.contains(doc.id)) return false;
              // Filtra avisos criados APÓS a data de instalação
              final avisoData = doc['data'];
              DateTime? dataAviso;
              if (avisoData is Timestamp) {
                dataAviso = avisoData.toDate();
              } else if (avisoData is String) {
                // Tenta parsear ISO ou dd/MM/yyyy
                dataAviso = DateTime.tryParse(avisoData);
                if (dataAviso == null && avisoData.contains('/')) {
                  final parts = avisoData.split('/');
                  if (parts.length == 3) {
                    try {
                      dataAviso = DateTime(
                        int.parse(parts[2]),
                        int.parse(parts[1]),
                        int.parse(parts[0]),
                      );
                    } catch (_) {}
                  }
                }
              }
              if (dataAviso == null) return false;
              return dataAviso.isAfter(_dataInstalacao!);
            }).toList();
            return ListView(
              padding: const EdgeInsets.all(25),
              children: docs
                  .map((doc) => Dismissible(
                        key: Key(doc.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          color: Colors.red,
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        confirmDismiss: (direction) async {
                          return await showDialog(
                            context: context,
                            builder: (BuildContext context) {
                              return AlertDialog(
                                title: const Text("Confirmar exclusão"),
                                content: const Text(
                                    "Tem certeza que deseja excluir este aviso?"),
                                actions: <Widget>[
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(false),
                                    child: const Text("Cancelar"),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(true),
                                    child: const Text("Excluir"),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                        onDismissed: (direction) async {
                          await _excluirAvisoLocal(doc.id);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content:
                                    Text('Aviso ocultado neste dispositivo')),
                          );
                        },
                        child: _GlassCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                doc['titulo'] ?? "",
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF818CF8)),
                              ),
                              Text(
                                doc['descricao'] ?? "",
                                style: const TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      ))
                  .toList(),
            );
          },
        ),
      );
}

class TelaFinanceiro extends StatelessWidget {
  const TelaFinanceiro({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text("Ofertas")),
        body: StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('config')
              .doc('home')
              .snapshots(),
          builder: (c, snap) {
            final chavePix = snap.data?['chavePix'] ?? "";
            return Padding(
              padding: const EdgeInsets.all(30),
              child: Center(
                child: _GlassCard(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(height: 16),
                      Icon(Icons.volunteer_activism,
                          color: Colors.amber, size: 48),
                      const SizedBox(height: 12),
                      const Text(
                        "Ajude a compartilhar o Amor de Deus.",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.amber,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.asset(
                          'assets/pix.jpg',
                          height: 220,
                          width: 220,
                          fit: BoxFit.contain,
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        "Chave Pix",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        chavePix,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: chavePix));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Chave Pix copiada!')),
                          );
                        },
                        icon: const Icon(Icons.copy),
                        label: const Text("Copiar Pix"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber,
                          foregroundColor: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
}

class TelaListaDoc extends StatelessWidget {
  final String coll;
  final String title;
  const TelaListaDoc({super.key, required this.coll, required this.title});

  Color _accentColor() {
    switch (coll) {
      case 'estudos':
        return const Color(0xFF4DA3FF);
      case 'crescimento':
        return const Color(0xFF3DDC97);
      case 'dinamicas':
        return const Color(0xFFFFA84D);
      case 'devocionais':
        return const Color(0xFFFFC857);
      default:
        return const Color(0xFF7C8CFF);
    }
  }

  IconData _sectionIcon() {
    switch (coll) {
      case 'estudos':
        return Icons.menu_book_rounded;
      case 'crescimento':
        return Icons.trending_up_rounded;
      case 'dinamicas':
        return Icons.auto_fix_high_rounded;
      case 'devocionais':
        return Icons.menu_book_rounded;
      default:
        return Icons.article_outlined;
    }
  }

    String _sectionDescription() {
    switch (coll) {
      case 'estudos':
        return 'Conteúdos organizados para aprofundar a palavra com clareza e ritmo visual melhor.';
      case 'crescimento':
        return 'Dicas práticas para líderes de célula aprimorarem a condução e o pastoreio.';
      case 'dinamicas':
        return 'Ideias rápidas para encontros mais vivos, com leitura mais leve e navegação direta.';
      case 'devocionais':
        return 'Mensagens para leitura e reflexão com destaque visual mais limpo.';
      default:
        return 'Explore os conteúdos disponíveis nesta seção.';
    }
  }

  Widget _buildStateView({
    required IconData icon,
    required String title,
    required String message,
    required Color accent,
  }) =>
      Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Container(
                  constraints: const BoxConstraints(maxWidth: 420),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                      color: Colors.white.withAlpha(8),
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(color: Colors.white.withAlpha(14))),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                        height: 58,
                        width: 58,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: accent.withAlpha(30)),
                        child: Icon(icon, color: accent, size: 28)),
                    const SizedBox(height: 16),
                    Text(title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white70, height: 1.45, fontSize: 13))
                  ]))));

  Widget _buildHeader(Color accent, int count) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [accent.withAlpha(50), Colors.white.withAlpha(8)]),
          border: Border.all(color: accent.withAlpha(55))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
                color: Colors.white.withAlpha(10),
                borderRadius: BorderRadius.circular(999)),
            child: Text(
                count == 1
                    ? '1 conteúdo disponível'
                    : '$count conteúdos disponíveis',
                style: TextStyle(
                    color: accent, fontWeight: FontWeight.w600, fontSize: 12))),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
              height: 54,
              width: 54,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withAlpha(18),
                  border: Border.all(color: Colors.white.withAlpha(16))),
              child: Icon(_sectionIcon(), color: Colors.white, size: 28)),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(_sectionDescription(),
                    style: const TextStyle(
                        color: Colors.white70, height: 1.45, fontSize: 13))
              ]))
        ])
      ]));

    Widget _buildDocCard(
      BuildContext context, QueryDocumentSnapshot<Object?> doc, Color accent) {
    final data = doc.data() as Map? ?? {};
    String titulo = data['titulo']?.toString() ?? '';
    String subtitulo = data['subtitulo']?.toString() ?? '';

    if (coll == 'relatorios_celula') {
      titulo = "Relatório - ${data['data'] ?? ''}";
      subtitulo = "Líder: ${data['lider'] ?? ''}";
    }

    if (titulo.isEmpty) titulo = doc.id;

    // Formata a data: se for Timestamp, converte para formato legível; se for string vazia, mantém 'Leitura disponível'
    String dataTexto = '';
    try {
      final dataField = data['data'];
      if (dataField != null) {
        if (dataField.runtimeType.toString() == 'Timestamp') {
          final dt = (dataField as dynamic).toDate() as DateTime;
          dataTexto = DateFormat.yMd('pt_BR').format(dt);
        } else if (dataField is String && dataField.isNotEmpty) {
          dataTexto = dataField;
        }
      }
    } catch (e) {
      dataTexto = '';
    }
    return Container(
        margin: const EdgeInsets.only(top: 14),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withAlpha(14),
                  Colors.white.withAlpha(6)
                ]),
            border: Border.all(color: Colors.white.withAlpha(14)),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withAlpha(24),
                  blurRadius: 20,
                  offset: const Offset(0, 12))
            ]),
        child: Material(
            color: Colors.transparent,
            child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (c) => TelaLeituraDoc(
                            id: doc.id, title: titulo, coll: coll),
                      ),
                    ),
                child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(children: [
                      Container(
                          height: 52,
                          width: 52,
                          decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              color: accent.withAlpha(22),
                              border: Border.all(color: accent.withAlpha(45))),
                          child: Icon(_sectionIcon(), color: accent, size: 24)),
                      const SizedBox(width: 16),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(titulo,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    height: 1.3,
                                    fontWeight: FontWeight.w700)),
                            if (subtitulo.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(subtitulo,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white70,
                                      height: 1.35,
                                      fontSize: 13))
                            ],
                            const SizedBox(height: 12),
                            Row(children: [
                              Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                      color: Colors.white.withAlpha(9),
                                      borderRadius: BorderRadius.circular(999)),
                                  child: Text(
                                      dataTexto.isEmpty
                                          ? 'Leitura disponível'
                                          : dataTexto,
                                      style: TextStyle(
                                          color: Colors.white.withAlpha(180),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w500))),
                            ])
                          ])),
                                                const SizedBox(width: 12),
                        Row(mainAxisSize: MainAxisSize.min, children: [
                        if (coll != 'relatorios_celula') ...[
                          Container(
                            height: 38,
                            width: 38,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withAlpha(10)),
                                                        child: IconButton(
                              icon: const Icon(Icons.share, size: 18, color: Colors.white),
                              padding: EdgeInsets.zero,
                                                            onPressed: () {
                                final textoOriginal = data['conteudo_html'] ?? data['texto'] ?? data['conteudo'];
                                final textoCompleto = _extrairTextoPuro(textoOriginal);
                                Share.share(
                                  '${titulo.toUpperCase()}\n'
                                  '${subtitulo.isNotEmpty ? "$subtitulo\n" : ""}'
                                  '\n$textoCompleto'
                                );
                              },
                              tooltip: 'Compartilhar conteúdo completo',
                            )),
                          const SizedBox(width: 8),
                        ],
                        Container(
                          height: 38,
                          width: 38,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withAlpha(10)),
                          child: const Icon(Icons.arrow_forward_rounded,
                            color: Colors.white, size: 18))
                        ])

                    ])))));
  }

    @override
  Widget build(BuildContext context) {
    Stream<QuerySnapshot> stream;
    final accent = _accentColor();
    final user = FirebaseAuth.instance.currentUser;

        if (coll == 'relatorios_celula' && user != null) {
      stream = FirebaseFirestore.instance
          .collection(coll)
          .where('user_id', isEqualTo: user.uid)
          .snapshots();
    } else if (title == 'Dicas para Líderes') {
      // Busca especificamente na coleção 'crescimento' quando o título for este
      stream = FirebaseFirestore.instance.collection('crescimento').snapshots();
    } else {
      // Busca diretamente na coleção passada (estudos, dinamicas, devocionais, etc)
      stream = FirebaseFirestore.instance.collection(coll).snapshots();
    }

    return Scaffold(
      backgroundColor: const Color(0xFF050B16),
      appBar: AppBar(
          title: Text(title),
          backgroundColor: Colors.transparent,
          elevation: 0),
      body: StreamBuilder<QuerySnapshot>(
        stream: stream,
        builder: (c, snap) {
          if (snap.hasError) {
            return _buildStateView(
              icon: Icons.error_outline_rounded,
              title: 'Não foi possível carregar',
              message: 'Erro ao carregar dados: ${snap.error}',
              accent: Colors.redAccent,
            );
          }
          if (snap.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator(color: accent));
          }
          if (!snap.hasData) {
            return _buildStateView(
              icon: _sectionIcon(),
              title: 'Nada por aqui ainda',
              message: 'Nenhum dado foi recebido para esta seção.',
              accent: accent,
            );
          }
                    final docs = (snap.data?.docs ?? []).where((d) {
                      final data = d.data() as Map? ?? {};
                      if (coll == 'relatorios_celula') return data.isNotEmpty;
                      return data.isNotEmpty &&
                          (data['titulo']?.toString() ?? '').isNotEmpty;
                    }).toList();

                    // Ordenação manual no lado do cliente (Data decrescente)
                    docs.sort((a, b) {
                      final dataA = (a.data() as Map)['data'];
                      final dataB = (b.data() as Map)['data'];
            
                      if (dataA == null) return 1;
                      if (dataB == null) return -1;

                      DateTime? dtA, dtB;
                      if (dataA is Timestamp) dtA = dataA.toDate();
                      if (dataB is Timestamp) dtB = dataB.toDate();
            
                      if (dtA != null && dtB != null) return dtB.compareTo(dtA);
                      return dataB.toString().compareTo(dataA.toString());
                    });

                    if (docs.isEmpty) {
            return Container(
                decoration: const BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF10213C), Color(0xFF050B16)])),
                child: Stack(children: [
                  Positioned(
                      top: -80,
                      right: -30,
                      child: _GlowOrb(color: accent.withAlpha(35), size: 220)),
                  ListView(padding: const EdgeInsets.all(20), children: [
                    _buildHeader(accent, 0),
                    const SizedBox(height: 24),
                    _buildStateView(
                      icon: _sectionIcon(),
                      title: 'Nenhum conteúdo disponível',
                      message:
                          'Essa área ainda não possui publicações. Assim que houver novos materiais, eles aparecerão aqui com destaque.',
                      accent: accent,
                    )
                  ])
                ]));
          }
          return Container(
              decoration: const BoxDecoration(
                  gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF10213C), Color(0xFF050B16)])),
              child: Stack(children: [
                Positioned(
                    top: -80,
                    right: -30,
                    child: _GlowOrb(color: accent.withAlpha(35), size: 220)),
                Positioned(
                    left: -70,
                    bottom: 100,
                    child: _GlowOrb(color: accent.withAlpha(18), size: 180)),
                ListView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                    children: [
                      _buildHeader(accent, docs.length),
                      const SizedBox(height: 10),
                      ...docs.map((d) => _buildDocCard(context, d, accent))
                    ])
              ]));
        },
      ),
    );
  }
}


class TelaInscricoes extends StatelessWidget {
  const TelaInscricoes({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Inscrições")),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('agenda')
            .where('inscricao', isEqualTo: true)
            .orderBy('dataEvento')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(
                child: Text("Nenhuma inscrição disponível.",
                    style: TextStyle(color: Colors.white)));
          }
          final docs = snapshot.data!.docs;
          return ListView.separated(
            padding: const EdgeInsets.all(25),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final d = docs[i].data() as Map<String, dynamic>;
              final nome = d['titulo'] ?? 'Evento';
              final dataEvento = d['dataEvento'];
              final dataEventoFim = d['dataEventoFim'];
              final valor = d['valor'] != null
                  ? double.tryParse(
                          d['valor'].toString().replaceAll(',', '.')) ??
                      0.0
                  : 0.0;
              String? dataEventoStr;
              String? dataFimStr;
              if (dataEvento != null && dataEvento is Timestamp) {
                final dt = dataEvento.toDate();
                dataEventoStr = DateFormat('dd/MM/yyyy').format(dt);
              }
              if (dataEventoFim != null && dataEventoFim is Timestamp) {
                final dt = dataEventoFim.toDate();
                dataFimStr = DateFormat('dd/MM/yyyy').format(dt);
              }
              return Card(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: ListTile(
                  title: Text(nome,
                      style: const TextStyle(
                          color: Colors.amber, fontWeight: FontWeight.bold)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (dataEventoStr != null)
                        Text('Data do evento: $dataEventoStr',
                            style: const TextStyle(color: Colors.white70)),
                      if (dataFimStr != null)
                        Text('Até: $dataFimStr',
                            style: const TextStyle(color: Colors.white70)),
                      if (valor > 0)
                        Text('Valor: R\$ ${valor.toStringAsFixed(2)}',
                            style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (c) => TelaInscricaoEvento(
                              inscricaoId: docs[i].id,
                              valor: valor > 0 ? valor : 0,
                              nomeEvento: nome,
                              formaPagamento: valor > 0
                                  ? FormaPagamento.pix
                                  : FormaPagamento.gratuito,
                            ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class TelaFormRelatorio extends StatefulWidget {
  const TelaFormRelatorio({super.key});

  @override
  State<TelaFormRelatorio> createState() => _TelaFormRelatorioState();
}

class _TelaFormRelatorioState extends State<TelaFormRelatorio> {
  final _formKey = GlobalKey<FormState>();
  final _dataController = TextEditingController();
  final _liderController = TextEditingController();
  final _membrosController = TextEditingController();
  final _convidadosController = TextEditingController();
  final _criancasController = TextEditingController();
  final _ofertasController = TextEditingController();
  final _observacoesController = TextEditingController();
  bool _supervisao = false;
  String _origem = 'Sede'; // Sede ou Núcleo
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Define a data atual como padrão
    final now = DateTime.now();
    _dataController.text =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
  }

  @override
  void dispose() {
    _dataController.dispose();
    _liderController.dispose();
    _membrosController.dispose();
    _convidadosController.dispose();
    _criancasController.dispose();
    _ofertasController.dispose();
    _observacoesController.dispose();
    super.dispose();
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      locale: const Locale('pt', 'BR'),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Colors.amber,
              onPrimary: Colors.black,
              surface: Color(0xFF1a1a2e),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        _dataController.text =
            '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
      });
    }
  }

  Future<void> _submitForm() async {
    if (!_formKey.currentState!.validate()) return;

    // Garantir que todos os campos obrigatórios estejam preenchidos corretamente
    final membrosStr = _membrosController.text.trim();
    final convidadosStr = _convidadosController.text.trim();
    final criancasStr = _criancasController.text.trim();
    final ofertasStr = _ofertasController.text.trim().replaceAll(',', '.');

    final membros = int.tryParse(membrosStr);
    final convidados = int.tryParse(convidadosStr);
    final criancas = int.tryParse(criancasStr);
    final ofertas = double.tryParse(ofertasStr);

    if (membros == null ||
        convidados == null ||
        criancas == null ||
        ofertas == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Preencha todos os campos numéricos corretamente!'),
        backgroundColor: Colors.red,
      ));
      return;
    }

        setState(() => _isLoading = true);

        try {
      final user = FirebaseAuth.instance.currentUser;
      // Dados base que vão para as planilhas (Sede ou Núcleo)
      final baseData = {
        'data': _dataController.text,
        'lider': _liderController.text.trim(),
        'membros_presentes': membros,
        'convidados': convidados,
        'criancas': criancas,
        'ofertas': ofertas,
        'supervisao': _supervisao,
        'observacoes': _observacoesController.text.trim(),
        'user_id': user?.uid,
        'user_name':
            user?.displayName ?? user?.email?.split('@').first ?? 'Anônimo',
      };

      if (_origem == 'Núcleo') {
        // Envio exclusivo para planilha Núcleo (sem salvar no Firestore e sem campo 'origem')
        await _sendToNucleoSheets(baseData);
      } else {
        // Fluxo normal Sede: Salva no Firestore (incluindo origem e timestamp)
        await FirebaseFirestore.instance.collection('relatorios_celula').add({
          ...baseData,
          'origem': 'Sede',
          'timestamp': FieldValue.serverTimestamp(),
        });

        // Envia para Planilha Sede (apenas os campos base)
        await _sendToGoogleSheets(baseData);
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Relatório enviado com sucesso!')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao enviar relatório: $e')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

    Future<void> _sendToNucleoSheets(Map<String, dynamic> data) async {
    const String scriptUrl =
        'https://script.google.com/macros/s/AKfycbxi3MpLDQ4YJL6_x6ZIOQJMIQhzdt-H54d41iQ_s_lCVSvp5vuW7u2PtZ4vt5oYWnMk/exec';
    const String spreadsheetId =
        '1CpdpQB1CVCO_z01HWlg1DQUCtUdXXjpK3GQod_8eqxo'; // ID da planilha NÚCLEO
    try {
      final response = await http.post(
        Uri.parse(scriptUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'spreadsheetId': spreadsheetId,
          'sheetName': 'Núcleo',
          'data': data,
        }),
      );
      if (response.statusCode != 200) {
        throw Exception('Erro na comunicação com o servidor (${response.statusCode})');
      }
      final responseData = jsonDecode(response.body);
      if (!responseData['success']) {
        throw Exception(responseData['error'] ?? 'Erro desconhecido na planilha');
      }
    } catch (e) {
      debugPrint('Erro ao enviar para planilha Núcleo: $e');
      rethrow;
    }
  }

    Future<void> _sendToGoogleSheets(Map<String, dynamic> data) async {
    // Relatório de Célula
    const String scriptUrl =
        'https://script.google.com/macros/s/AKfycbxi3MpLDQ4YJL6_x6ZIOQJMIQhzdt-H54d41iQ_s_lCVSvp5vuW7u2PtZ4vt5oYWnMk/exec';
    const String spreadsheetId =
        '1hRmGeYYvKyxHJw2NpLNMRAK2ThqLkUo0SwfEy12otc4'; // ID da planilha CÉLULAS
    try {
      final response = await http.post(
        Uri.parse(scriptUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'spreadsheetId': spreadsheetId,
          'sheetName': 'Células',
          'data': data,
        }),
      );
      if (response.statusCode == 302) {
        debugPrint(
            'Aviso: resposta 302 recebida do Apps Script (redirecionamento).');
        return;
      }
      if (response.statusCode != 200) {
        throw Exception(
            'Erro ao enviar para planilha: [${response.statusCode}');
      }
      final responseData = jsonDecode(response.body);
      if (!responseData['success']) {
        throw Exception('Erro na planilha: [${responseData['error']}');
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Aviso: Relatório salvo localmente, mas houve erro na sincronização com planilha: $e')),
        );
      }
    }
  }

  Future<void> _sendToCultosSheets(Map<String, dynamic> data) async {
    // Relatório de Culto
    const String scriptUrl =
        'https://script.google.com/macros/s/AKfycbzx3HjDdBglzkcUGfNu9zIFAqL8QNmzlEcCQJF1Civ5NkR6Xt4pSisJ2nbXz0iiQOBv/exec';
    const String spreadsheetId =
        '12toKDAHQSRRQrOE7nvGk834JVXdqztbXiz2vc5HpyRY'; // ID da planilha CULTOS
    try {
      final response = await http.post(
        Uri.parse(scriptUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'spreadsheetId': spreadsheetId,
          'sheetName': 'Cultos',
          'data': data,
        }),
      );
      if (response.statusCode == 302) {
        debugPrint(
            'Aviso: resposta 302 recebida do Apps Script (redirecionamento).');
        return;
      }
      if (response.statusCode != 200) {
        throw Exception(
            'Erro ao enviar para planilha: [${response.statusCode}');
      }
      final responseData = jsonDecode(response.body);
      if (!responseData['success']) {
        throw Exception('Erro na planilha: [${responseData['error']}');
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Aviso: Relatório salvo localmente, mas houve erro na sincronização com planilha: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Relatório de Célula'),
        actions: [
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.list),
              tooltip: 'Ver relatórios enviados',
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (c) => const TelaListaDoc(
                          coll: 'relatorios_celula',
                          title: 'Relatórios Enviados'))),
            ),
          ],
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            _buildTextField(
              controller: _dataController,
              label: 'Data da reunião',
              readOnly: true,
              onTap: () => _selectDate(context),
              validator: (value) {
                if (value?.isEmpty ?? true) return 'Campo obrigatório';
                return null;
              },
            ),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _liderController,
              label: 'Líder',
              validator: (value) {
                if (value?.isEmpty ?? true) return 'Campo obrigatório';
                return null;
              },
            ),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _membrosController,
              label: 'Membros presentes',
              keyboardType: TextInputType.number,
              validator: (value) {
                if (value?.isEmpty ?? true) return 'Campo obrigatório';
                if (int.tryParse(value!) == null) {
                  return 'Digite um número válido';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _convidadosController,
              label: 'Convidados',
              keyboardType: TextInputType.number,
              validator: (value) {
                if (value?.isEmpty ?? true) return 'Campo obrigatório';
                if (int.tryParse(value!) == null) {
                  return 'Digite um número válido';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _criancasController,
              label: 'Crianças',
              keyboardType: TextInputType.number,
              validator: (value) {
                if (value?.isEmpty ?? true) return 'Campo obrigatório';
                if (int.tryParse(value!) == null) {
                  return 'Digite um número válido';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _ofertasController,
              label: 'Ofertas (R\$)',
              keyboardType: TextInputType.numberWithOptions(decimal: true),
              validator: (value) {
                if (value?.isEmpty ?? true) return 'Campo obrigatório';
                final numValue = double.tryParse(value!.replaceAll(',', '.'));
                if (numValue == null) return 'Digite um valor válido';
                return null;
              },
            ),
            const SizedBox(height: 16),
                        _GlassCard(
              child: SwitchListTile(
                title: const Text('Houve Supervisão?',
                    style: TextStyle(color: Colors.white)),
                value: _supervisao,
                onChanged: (value) => setState(() => _supervisao = value),
                activeColor: Colors.amber,
              ),
            ),
            const SizedBox(height: 16),
            _GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Origem da Célula',
                      style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ChoiceChip(
                          label: const Center(child: Text('Sede')),
                          selected: _origem == 'Sede',
                          onSelected: (bool selected) {
                            setState(() => _origem = 'Sede');
                          },
                          selectedColor: Colors.amber,
                          labelStyle: TextStyle(
                              color: _origem == 'Sede' ? Colors.black : Colors.white),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ChoiceChip(
                          label: const Center(child: Text('Núcleo')),
                          selected: _origem == 'Núcleo',
                          onSelected: (bool selected) {
                            setState(() => _origem = 'Núcleo');
                          },
                          selectedColor: Colors.amber,
                          labelStyle: TextStyle(
                              color: _origem == 'Núcleo' ? Colors.black : Colors.white),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _observacoesController,
              label: 'Observações',
              maxLines: 3,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.send),
              label: const Text('Enviar Relatório'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                padding: const EdgeInsets.symmetric(vertical: 16),
                textStyle:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              onPressed: _isLoading ? null : _submitForm,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    TextInputType? keyboardType,
    bool readOnly = false,
    VoidCallback? onTap,
    String? Function(String?)? validator,
    int? maxLines,
  }) {
    return _GlassCard(
      child: TextFormField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white70),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Colors.white30),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Colors.white30),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Colors.amber),
          ),
        ),
        style: const TextStyle(color: Colors.white),
        keyboardType: keyboardType,
        readOnly: readOnly,
        onTap: onTap,
        validator: validator,
        maxLines: maxLines ?? 1,
      ),
    );
  }
}

class TelaVoltsMembro extends StatelessWidget {
  const TelaVoltsMembro({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text("QR")),
      body: Center(
          child: _GlassCard(
              child: QrImageView(
                  data: FirebaseAuth.instance.currentUser!.uid,
                  size: 200,
                  backgroundColor: Colors.white))));
}

class TelaOperadorVolts extends StatelessWidget {
  final bool isCheckin;
  const TelaOperadorVolts({super.key, required this.isCheckin});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(isCheckin ? "Check-in" : "Check-out")),
      body: MobileScanner(onDetect: (c) {}));
}

class TelaLoginMembro extends StatelessWidget {
  const TelaLoginMembro({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
          body: Center(
              child: _GlassCard(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.lock, size: 40, color: Colors.amber),
        ElevatedButton(
            onPressed: () =>
                FirebaseAuth.instance.signInWithPopup(GoogleAuthProvider()),
            child: const Text("Login Google"))
      ]))));
}

class TelaCadastroMembro extends StatefulWidget {
  const TelaCadastroMembro({super.key});
  @override
  State<TelaCadastroMembro> createState() => _TelaCadastroMembroState();
}

class _TelaCadastroMembroState extends State<TelaCadastroMembro> {
  final _nomeController = TextEditingController();
  final _ministerioController = TextEditingController();
  final _nascimentoController = TextEditingController();
  
  final _nascimentoMask = MaskTextInputFormatter(
    mask: '##/##/####',
    filter: {"#": RegExp(r'[0-9]')},
    type: MaskAutoCompletionType.lazy,
  );

  bool _isLoading = false;
  bool _isSaving = false;
  Map<String, dynamic>? _userData;

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    setState(() => _isLoading = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final doc = await FirebaseFirestore.instance
            .collection('usuarios')
            .doc(user.uid)
            .get();
        if (doc.exists) {
          _userData = doc.data();
          _nomeController.text = _userData?['nome'] ?? '';
          _ministerioController.text = _userData?['ministerio'] ?? '';
          _nascimentoController.text = _userData?['nascimento'] ?? '';
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao carregar dados: $e')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveData() async {
    if (_nomeController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nome é obrigatório')),
      );
      return;
    }

    if (_ministerioController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ministério é obrigatório')),
      );
      return;
    }

    if (_nascimentoController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Data de nascimento é obrigatória')),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await FirebaseFirestore.instance
            .collection('usuarios')
            .doc(user.uid)
            .set({
          'nome': _nomeController.text.trim(),
          'ministerio': _ministerioController.text.trim(),
          'nascimento': _nascimentoController.text.trim(),
          'email': user.email,
          'uid': user.uid,
          'dataCadastro': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Dados salvos com sucesso!')),
          );
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao salvar: $e')),
        );
      }
    } finally {
      setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Minha Identidade'),
        backgroundColor: Colors.transparent,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(25),
              child: Column(
                children: [
                  _GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Complete seu cadastro',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Essas informações são necessárias para gerar seu QR Code único.',
                          style: TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 30),
                        TextField(
                          controller: _nomeController,
                          decoration: const InputDecoration(
                            labelText: 'Nome completo',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.person),
                          ),
                          style: const TextStyle(color: Colors.white),
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          controller: _ministerioController,
                          decoration: const InputDecoration(
                            labelText: 'Ministério',
                            hintText: 'Ex: Louvor, Dança, Coreografia...',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.work),
                          ),
                          style: const TextStyle(color: Colors.white),
                        ),
                        const SizedBox(height: 20),
                                                TextField(
                          controller: _nascimentoController,
                          inputFormatters: [_nascimentoMask],
                          decoration: const InputDecoration(
                            labelText: 'Data de nascimento',
                            hintText: 'DD/MM/AAAA',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.calendar_today),
                          ),
                          style: const TextStyle(color: Colors.white),
                          keyboardType: TextInputType.number,
                        ),
                        const SizedBox(height: 30),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _isSaving ? null : _saveData,
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                            child: _isSaving
                                ? const CircularProgressIndicator()
                                : const Text('SALVAR E GERAR QR CODE'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_userData != null) ...[
                    const SizedBox(height: 20),
                    _GlassCard(
                      child: Column(
                        children: [
                          const Text(
                            'Seu QR Code',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 20),
                          QrImageView(
                            data: FirebaseAuth.instance.currentUser!.uid,
                            size: 200,
                            backgroundColor: Colors.white,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'Este QR Code é sua identidade digital de membro.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.amber,
                                fontWeight: FontWeight.bold,
                                fontSize: 13),
                          ),
                          SizedBox(height: 10),
                          Divider(color: Colors.white24),
                          SizedBox(height: 10),
                          Text(
                            'Como usar para Check-in/Check-out:',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13),
                            textAlign: TextAlign.center,
                          ),
                          SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    '1. Abra esta tela e mostre seu QR Code ao operador.',
                                    style: TextStyle(
                                        color: Colors.white70, fontSize: 12)),
                                Text(
                                    '2. O operador irá escanear seu QR Code no app.',
                                    style: TextStyle(
                                        color: Colors.white70, fontSize: 12)),
                                Text(
                                    '3. Confirme os itens recebidos/devolvidos conforme solicitado.',
                                    style: TextStyle(
                                        color: Colors.white70, fontSize: 12)),
                                Text(
                                    '4. Pronto! Seu check-in/check-out será registrado.',
                                    style: TextStyle(
                                        color: Colors.white70, fontSize: 12)),
                              ],
                            ),
                          ),
                          SizedBox(height: 10),
                          Text(
                              'Dica: Não compartilhe este QR Code com outras pessoas.',
                              style: TextStyle(
                                  color: Colors.redAccent, fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  @override
  void dispose() {
    _nomeController.dispose();
    _ministerioController.dispose();
    _nascimentoController.dispose();
    super.dispose();
  }
}

class _GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  const _GlassCard(
      {required this.child,
      this.padding = const EdgeInsets.all(20),
      this.radius = 18});
  @override
  Widget build(BuildContext context) => Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
          color: Colors.white.withAlpha(12),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: Colors.white.withAlpha(16)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withAlpha(18),
                blurRadius: 18,
                offset: const Offset(0, 10))
          ]),
      child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Padding(padding: padding, child: child))));
}

class _GlowOrb extends StatelessWidget {
  final Color color;
  final double size;
  const _GlowOrb({required this.color, required this.size});

  @override
  Widget build(BuildContext context) => IgnorePointer(
      child: Container(
          height: size,
          width: size,
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [color, Colors.transparent]))));
}

class _AdsBanner extends StatelessWidget {
  final String title;
  final String url;
  const _AdsBanner({required this.title, required this.url});
  @override
  Widget build(BuildContext context) => InkWell(
      onTap: () => launchUrl(Uri.parse(url)),
      child: Container(
          padding: const EdgeInsets.all(25),
          decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [Colors.indigo, Colors.blueAccent]),
              borderRadius: BorderRadius.circular(20)),
          child: Row(children: [
            const Icon(Icons.library_books),
            const SizedBox(width: 15),
            Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.white))),
            const Icon(Icons.open_in_new, size: 14)
          ])));
}

// --- TELA CHECKLIST DO CULTO ---
class TelaChecklistCulto extends StatefulWidget {
  const TelaChecklistCulto({super.key});

  @override
  State<TelaChecklistCulto> createState() => _TelaChecklistCultoState();
}

class _TelaChecklistCultoState extends State<TelaChecklistCulto> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  final List<List<String>> _tarefasPorMomento = [
    [
      'Chegar ao prédio da Igreja.',
      'Verificar se o controle dos ar-condicionados do auditório está no modo automático e em 22 graus',
      'Ligar os ar-condicionados do auditório | modo automático | 20 graus',
      'Ligar as luzes do auditório, do hall de entrada e do Paz Coffee',
      'Ligar as luzes e os ar-condicionados das salas do PazKids | 20 graus',
      'Ligar as luzes azuis na galeria',
      'Ligar as luzes dos banheiros masculinos e femininos',
      'Abrir o cadeado do portão lateral',
      'Verificar se os voluntários do Atmosfera estão posicionados',
      'Verificar se o voluntário da mídia já ligou o sistema de iluminação e os telões.',
      'Apresentar-se para o Líder de Louvor e verificar se está tudo certo',
      'Apagar os refletores grandes do auditório',
      'Verificar se a contagem regressiva já está nas telas.',
      'Verificar se o Ministério de louvor está pronto na plataforma'
    ],
    [
      'Verificar se a letra da música está aparecendo corretamente nas telas.',
      'Verificar se o volume do auditório está agradável',
      'Verificar se o(a) Assistente de Culto já está dentro do Auditório, preparado para fazer a oração.',
      'Ligar e entregar o microfone para o Assistente de Culto;',
      'Lembrar o Assistente do Culto de que ele deve liberar o PazKids durante o Minuto Conexão',
      'Verificar se o preletor já está no Auditório',
      'Verificar se está tudo "ok” com a equipe de voluntários que recolhe as ofertas.',
      'Permanecer dentro do Auditório desde antes da transição do louvor para o assistente, até o momento que o preletor subir.',
      'Verificar se temos pelo menos um casal na entrada do prédio da igreja durante todo o culto.',
      'Ligar e entregar o microfone para o preletor ou introdutor do preletor.',
      'Passar novamente pelo Estacionamento, Atmosfera e Paz Kids para verificar se está indo tudo bem.',
      'Lembrar o Ministério de Louvor para entrar na hora que o preletor pedir para a igreja ficar em pé',
      'Verificar se temos voluntários nas portas, para despedir as pessoas na saída.'
    ],
    [
      'Desligar as luzes e os ar-condicionados das Salas do Paz Kids',
      'Se não houver muitas pessoas dentro do prédio, desligar os ar-condicionados do auditório principal.',
      'Guardar o controle no local apropriado',
      'Ligar os refletores grandes do auditório'
    ]
  ];

  final Map<int, List<bool>> _concluidas = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    for (int i = 0; i < 3; i++) {
      _concluidas[i] = List.generate(_tarefasPorMomento[i].length, (index) => false);
    }
    _loadChecklist();
  }

  Future<void> _loadChecklist() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      for (int i = 0; i < 3; i++) {
        final saved = prefs.getStringList('checklist_momento_$i');
        if (saved != null && saved.length == _tarefasPorMomento[i].length) {
          _concluidas[i] = saved.map((e) => e == 'true').toList();
        }
      }
      _isLoading = false;
    });
  }

  Future<void> _saveChecklist(int momentoIndex) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'checklist_momento_$momentoIndex', _concluidas[momentoIndex]!.map((e) => e.toString()).toList());
  }

  Future<void> _limparChecklist() async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reiniciar Checklist?'),
        content: const Text('Isso irá apagar todo o progresso dos 3 momentos.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCELAR')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('REINICIAR'),
          ),
        ],
      ),
    );

    if (confirmar == true) {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        for (int i = 0; i < 3; i++) {
          _concluidas[i] = List.generate(_tarefasPorMomento[i].length, (index) => false);
          prefs.remove('checklist_momento_$i');
        }
        _tabController.animateTo(0);
      });
    }
  }

  bool _isMomentoCompleto(int index) {
    return !_concluidas[index]!.contains(false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020617),
      appBar: AppBar(
        title: const Text('Checklist do Culto'),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.amber),
            tooltip: 'Reiniciar Tudo',
            onPressed: _limparChecklist,
          )
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.amber,
          labelColor: Colors.amber,
          unselectedLabelColor: Colors.white54,
          tabs: [
            Tab(text: 'ANTES', icon: Icon(_isMomentoCompleto(0) ? Icons.check_circle : Icons.looks_one, size: 18)),
            Tab(text: 'DURANTE', icon: Icon(_isMomentoCompleto(1) ? Icons.check_circle : Icons.looks_two, size: 18)),
            Tab(text: 'APÓS', icon: Icon(_isMomentoCompleto(2) ? Icons.check_circle : Icons.looks_3, size: 18)),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildMomentList(0),
                _buildMomentList(1),
                _buildMomentList(2),
              ],
            ),
    );
  }

  Widget _buildMomentList(int mIndex) {
    final tarefas = _tarefasPorMomento[mIndex];
    final bool isAnteriorCompleto = mIndex == 0 || _isMomentoCompleto(mIndex - 1);
    
    if (!isAnteriorCompleto) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 64, color: Colors.white24),
              const SizedBox(height: 20),
              Text(
                'Momento Bloqueado',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Text(
                'Conclua todas as tarefas do momento anterior para liberar este.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      itemCount: tarefas.length,
      itemBuilder: (context, index) {
        final isDone = _concluidas[mIndex]![index];
        return AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: isDone ? 0.5 : 1.0,
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: isDone ? Colors.white.withAlpha(5) : Colors.white.withAlpha(12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDone ? Colors.transparent : Colors.white12),
            ),
            child: CheckboxListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              value: isDone,
              activeColor: Colors.green,
              checkColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Text(
                tarefas[index],
                style: TextStyle(
                  color: isDone ? Colors.white38 : Colors.white,
                  fontSize: 14,
                  decoration: isDone ? TextDecoration.lineThrough : null,
                ),
              ),
              onChanged: (val) {
                setState(() {
                  _concluidas[mIndex]![index] = val ?? false;
                  
                  // Se completou a última tarefa do momento, sugere pular para o próximo
                  if (_isMomentoCompleto(mIndex) && mIndex < 2) {
                    Future.delayed(const Duration(milliseconds: 500), () {
                      if (mounted) _tabController.animateTo(mIndex + 1);
                    });
                  }
                });
                _saveChecklist(mIndex);
              },
            ),
          ),
        );
      },
    );
  }
}


