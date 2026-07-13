// Script para aplicar patches em pacotes da pub-cache
// Usa package_config.json para localizar os arquivos exatos

import 'dart:convert';
import 'dart:io';

void main() {
  final configFile = File('.dart_tool/package_config.json');
  if (!configFile.existsSync()) {
    print('❌ package_config.json não encontrado. Execute flutter pub get primeiro.');
    exit(1);
  }

  final config = jsonDecode(configFile.readAsStringSync()) as Map;
  final packages = config['packages'] as List;

  for (final pkg in packages) {
    final name = pkg['name'] as String;
    final rootUri = pkg['rootUri'] as String;

    // Converte file:// para caminho absoluto
    String path;
    if (rootUri.startsWith('file://')) {
      path = Uri.parse(rootUri).toFilePath();
    } else {
      path = rootUri;
    }

    switch (name) {
      case 'quill_native_bridge_windows':
        _patchQuillNativeBridgeWindows(path);
        break;
      case 'google_fonts':
        _patchGoogleFonts(path);
        break;
      case 'flutter_quill':
        _patchFlutterQuill(path);
        break;
    }
  }
}

void _patchQuillNativeBridgeWindows(String packagePath) {
  final file = File('$packagePath/lib/quill_native_bridge_windows.dart');
  if (!file.existsSync()) {
    print('⚠️ quill_native_bridge_windows.dart não encontrado');
    return;
  }

  var content = file.readAsStringSync();
  final original = content;
  content = content.replaceAll(
    'GlobalAlloc(GMEM_MOVEABLE',
    'GlobalAlloc(GLOBAL_ALLOC_FLAGS.GMEM_MOVEABLE',
  );

  if (content != original) {
    file.writeAsStringSync(content);
    print('✅ Patch quill_native_bridge_windows: ${file.path}');
  } else {
    print('➡️ quill_native_bridge_windows já está patchado');
  }
}

void _patchGoogleFonts(String packagePath) {
  final file = File('$packagePath/lib/src/google_fonts_variant.dart');
  if (!file.existsSync()) {
    print('⚠️ google_fonts_variant.dart não encontrado');
    return;
  }

  var content = file.readAsStringSync();
  final original = content;
  content = content.replaceFirst(
    'const _fontWeightToFilenameWeightParts = {',
    'final _fontWeightToFilenameWeightParts = {',
  );

  if (content != original) {
    file.writeAsStringSync(content);
    print('✅ Patch google_fonts: ${file.path}');
  } else {
    print('➡️ google_fonts já está patchado');
  }
}

void _patchFlutterQuill(String packagePath) {
  final file = File(
    '$packagePath/lib/src/editor/raw_editor/raw_editor_state_text_input_client_mixin.dart',
  );
  if (!file.existsSync()) {
    print('⚠️ flutter_quill mixin não encontrado');
    return;
  }

  var content = file.readAsStringSync();
  if (content.contains('onFocusReceived')) {
    print('➡️ flutter_quill já está patchado');
    return;
  }

  // Remove o último } e adiciona o método
  content = content.trimRight();
  if (content.endsWith('}')) {
    content = content.substring(0, content.lastIndexOf('}'));
    content += '  @override\n  bool onFocusReceived() => false;\n}\n';
    file.writeAsStringSync(content);
    print('✅ Patch flutter_quill (onFocusReceived): ${file.path}');
  } else {
    print('⚠️ flutter_quill: formato inesperado');
  }
}
