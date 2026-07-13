import 'dart:convert';
import 'package:http/http.dart' as http;

class GoogleAIService {
  final String apiKey;
  GoogleAIService(this.apiKey);

  Future<String> explainVerse(String verse) async {
    final url = Uri.parse('https://generativelanguage.googleapis.com/v1/models/gemini-2.5-pro:generateContent?key=$apiKey');
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {
                'text': 'Explique e resuma o seguinte versículo bíblico de forma clara e prática para leigos: "$verse"'
              }
            ]
          }
        ]
      }),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['candidates']?[0]?['content']?['parts']?[0]?['text']?.trim() ?? 'Sem resposta.';
    } else {
      return 'Erro ao consultar IA Google: ${response.body}';
    }
  }

  /// Gera um convite personalizado para um evento usando IA
  Future<String> generateEventInvite(String eventTitle, String eventDate, String eventTime, bool isMultiDay) async {
    final url = Uri.parse('https://generativelanguage.googleapis.com/v1/models/gemini-2.5-pro:generateContent?key=$apiKey');
    
    final prompt = isMultiDay
        ? 'Crie um convite criativo e entusiasmante (máx 200 caracteres) para um evento religioso/evangélico chamado "$eventTitle" que acontecerá em $eventDate. Comece com um convite atrativo, não use "Você é nosso convidado para".'
        : 'Crie um convite criativo e entusiasmante (máx 200 caracteres) para um evento religioso/evangélico chamado "$eventTitle" que acontecerá em $eventDate às $eventTime. Comece com um convite atrativo, não use "Você é nosso convidado para".';
    
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {
                'text': prompt
              }
            ]
          }
        ]
      }),
    );
    
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['candidates']?[0]?['content']?['parts']?[0]?['text']?.trim() ?? _getFallbackInvite(eventTitle, eventDate, eventTime);
    } else {
      return _getFallbackInvite(eventTitle, eventDate, eventTime);
    }
  }

  /// Convite padrão caso a IA falhe
  String _getFallbackInvite(String title, String date, String time) {
    return 'Você é nosso convidado para $title em $date${time.isNotEmpty ? " às $time" : ""}';
  }
}
