import 'dart:convert';
import 'dart:io' show Platform;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';

class UpdateService {
  // CONFIGURAÇÃO: Coloque seus dados aqui
  final String owner = "pazapps";
  final String repo = "paz-cast-app";

  /// App Store URL (preencher quando o app estiver publicado)
  final String appStoreUrl = 'https://apps.apple.com/app/idYOUR_APP_ID';

  Future<void> checkForUpdates(BuildContext context) async {
    try {
      // 1. Pega a versão atual do aplicativo instalado
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      String currentVersion = packageInfo.version;

      // 2. Consulta a última release no GitHub
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        String latestVersion = data['tag_name'].toString().replaceAll('v', '');

        // 3. Compara as versões
        if (_isVersionGreater(latestVersion, currentVersion)) {
          _showUpdateDialog(context, latestVersion);
        }
      }
    } catch (e) {
      print("Erro ao verificar atualização: $e");
    }
  }

  bool _isVersionGreater(String latest, String current) {
    return latest.compareTo(current) > 0;
  }

  void _showUpdateDialog(BuildContext context, String version) {
    final isIOS = Platform.isIOS;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Nova Atualização Disponível!"),
        content: Text(
          isIOS
              ? "Uma nova versão ($version) está disponível na App Store. Deseja atualizar agora?"
              : "Uma nova versão ($version) está disponível. Deseja baixar agora?",
        ),
        actions: [
          TextButton(
            child: const Text("Depois"),
            onPressed: () => Navigator.pop(context),
          ),
          ElevatedButton(
            child: Text(isIOS ? "Abrir App Store" : "Baixar Agora"),
            onPressed: () async {
              final uri = Uri.parse(
                isIOS ? appStoreUrl : _getDownloadUrl(version),
              );
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          ),
        ],
      ),
    );
  }

  /// Busca a URL de download da release para Android
  String _getDownloadUrl(String version) {
    return 'https://github.com/$owner/$repo/releases/tag/v$version';
  }
}