import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_cupertino_date_picker_fork/flutter_cupertino_date_picker_fork.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'main.dart' show enviarInscricaoParaPlanilha;

enum FormaPagamento { pix, igreja, gratuito }

class TelaInscricaoEvento extends StatefulWidget {
  final String inscricaoId;
  final double valor;
  final String nomeEvento;
  final FormaPagamento formaPagamento;

  const TelaInscricaoEvento({
    super.key,
    required this.inscricaoId,
    required this.valor,
    required this.nomeEvento,
    required this.formaPagamento,
  });

  @override
  State<TelaInscricaoEvento> createState() => _TelaInscricaoEventoState();
}

class _TelaInscricaoEventoState extends State<TelaInscricaoEvento> {
    /// Remove acentos e substitui espaços por underline para nome de aba
    String normalizarNomeAba(String nome) {
      var comAcentos = 'ÀÁÂÃÄÅàáâãäåÒÓÔÕÖØòóôõöøÈÉÊËèéêëÇçÌÍÎÏìíîïÙÚÛÜùúûüÿÑñ';
      var semAcentos = 'AAAAAAaaaaaaOOOOOOooooooEEEEeeeeCcIIIIiiiiUUUUuuuuyNn';
      String output = nome;
      for (int i = 0; i < comAcentos.length; i++) {
        output = output.replaceAll(comAcentos[i], semAcentos[i]);
      }
      return output.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    }
  final _formKey = GlobalKey<FormState>();
  final _nomeController = TextEditingController();
  final _nascimentoController = TextEditingController();
  final _celularController = TextEditingController();

  // Função para permitir apenas números e limitar a 11 dígitos
  void _onCelularChanged(String value) {
    final digitsOnly = value.replaceAll(RegExp(r'\D'), '');
    if (digitsOnly.length > 11) {
      _celularController.text = digitsOnly.substring(0, 11);
      _celularController.selection = TextSelection.fromPosition(
        TextPosition(offset: _celularController.text.length),
      );
    } else if (digitsOnly != value) {
      _celularController.text = digitsOnly;
      _celularController.selection = TextSelection.fromPosition(
        TextPosition(offset: digitsOnly.length),
      );
    }
  }
  bool _enviando = false;
  DateTime? _dataNascimento;

  // Função para formatar o celular enquanto o usuário digita
  void _formatarCelular(String valor) {
    // Implementação básica de máscara (pode ser melhorada com pacotes de mask)
    print("Formatando: $valor");
  }

  // Abre o seletor de data
  void _selecionarDataNascimento() {
    DatePicker.showDatePicker(
      context,
      dateFormat: 'dd/MM/yyyy',
      locale: DateTimePickerLocale.pt_br,
      onConfirm: (dateTime, selectedIndex) {
        setState(() {
          _dataNascimento = dateTime;
          _nascimentoController.text = DateFormat('dd/MM/yyyy').format(dateTime);
        });
      },
    );
  }


  Future<void> _enviarInscricao() async {
    debugPrint('[Inscricao] Iniciando envio. nome: \\${_nomeController.text}, nascimento: \\${_nascimentoController.text}, celular: \\${_celularController.text}');
    if (!_formKey.currentState!.validate()) {
      debugPrint('[Inscricao] Formulário inválido.');
      return;
    }
    if (widget.formaPagamento == FormaPagamento.gratuito) {
      setState(() => _enviando = true);
      final data = {
        'inscricaoId': widget.inscricaoId,
        'nome': _nomeController.text,
        'nascimento': _nascimentoController.text,
        'celular': _celularController.text,
        'status': 'Gratuito',
        'timestamp': DateTime.now().toIso8601String(),
      };
      try {
        await enviarInscricaoParaPlanilha(
          data: data,
          nomeAba: normalizarNomeAba(widget.nomeEvento),
          situacao: 'Gratuito',
        );
      } catch (e) {
        debugPrint('Erro ao enviar inscrição gratuita: $e');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Inscrição realizada com sucesso!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
      if (mounted) setState(() => _enviando = false);
      return;
        } else if (widget.formaPagamento == FormaPagamento.pix) {
      // Fluxo novo: Buscar link na coleção 'inscricoes' e abrir WebView
      setState(() => _enviando = true);
      try {
        final doc = await FirebaseFirestore.instance
          .collection('agenda')
          .doc(widget.inscricaoId)
          .get();

        final paymentLink = doc.data()?['link']?.toString() ?? '';

        if (paymentLink.isEmpty) {
          throw Exception('Link de pagamento não configurado para este evento.');
        }

        if (mounted) {
          // Abre o WebView dentro do app
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (c) => TelaWebViewPagamento(
                url: paymentLink,
                onSuccess: () async {
                  // Ao fechar/sucesso do WebView, registra na planilha
                  final data = {
                    'inscricaoId': widget.inscricaoId,
                    'nome': _nomeController.text,
                    'nascimento': _nascimentoController.text,
                    'celular': _celularController.text,
                    'status': 'Inscrição Confirmada',
                    'timestamp': DateTime.now().toIso8601String(),
                  };
                  await enviarInscricaoParaPlanilha(
                    data: data,
                    nomeAba: normalizarNomeAba(widget.nomeEvento),
                    situacao: 'Confirmado via Link',
                  );
                  
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Inscrição finalizada!'),
                        backgroundColor: Colors.green,
                        duration: Duration(seconds: 3),
                      ),
                    );
                    // Volta para a página inicial
                    Navigator.of(context).popUntil((route) => route.isFirst);
                  }
                },
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.red),
          );
        }
      } finally {
        if (mounted) setState(() => _enviando = false);
      }
    } else {
      setState(() => _enviando = true);
      final data = {
        'inscricaoId': widget.inscricaoId,
        'nome': _nomeController.text,
        'nascimento': _nascimentoController.text,
        'celular': _celularController.text,
        'status': 'Pagar na Igreja',
        'timestamp': DateTime.now().toIso8601String(),
      };
      try {
        await enviarInscricaoParaPlanilha(
          data: data,
          nomeAba: normalizarNomeAba(widget.nomeEvento),
          situacao: 'Aguardando Pagamento',
        );
      } catch (e) {
        debugPrint('Erro ao enviar inscrição para planilha (Pagar na Igreja): $e');
        // Mesmo com erro, segue o fluxo de sucesso para o usuário
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Inscrição enviada! Aguardando pagamento!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Inscrição - ${widget.nomeEvento}')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView( // Usado para evitar erro de overflow no teclado
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nomeController,
                  decoration: const InputDecoration(labelText: 'Nome completo'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Informe o nome' : null,
                ),
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: _selecionarDataNascimento,
                  child: AbsorbPointer(
                    child: TextFormField(
                      controller: _nascimentoController,
                      decoration: const InputDecoration(
                        labelText: 'Data de nascimento',
                        hintText: 'Selecione a data',
                        suffixIcon: Icon(Icons.calendar_today),
                      ),
                      readOnly: true,
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return 'Informe a data de nascimento';
                        }
                        return null;
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _celularController,
                  decoration: const InputDecoration(
                    labelText: 'Celular',
                    hintText: '(99) 99999-9999',
                  ),
                  keyboardType: TextInputType.number,
                  maxLength: 11,
                  onChanged: _onCelularChanged,
                  validator: (v) {
                    final digits = v?.replaceAll(RegExp(r'\D'), '') ?? '';
                    if (digits.isEmpty) return 'Informe o celular';
                    if (digits.length != 11) return 'Celular deve ter 11 dígitos';
                    return null;
                  },
                ),
                                const SizedBox(height: 32),
                if (widget.formaPagamento != FormaPagamento.gratuito)
                  Text(
                    'Valor da inscrição: R\$ ${widget.valor.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: widget.formaPagamento == FormaPagamento.pix
                        ? const Icon(Icons.payment)
                        : widget.formaPagamento == FormaPagamento.igreja
                            ? const Icon(Icons.church)
                            : const Icon(Icons.check_circle),
                    label: _enviando
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(widget.formaPagamento == FormaPagamento.pix
                            ? 'Pagar Agora'
                            : 'Confirmar Inscrição'),
                    onPressed: _enviando ? null : _enviarInscricao,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.formaPagamento == FormaPagamento.pix
                          ? const Color(0xFF1565C0)
                          : widget.formaPagamento == FormaPagamento.gratuito
                              ? const Color(0xFF1565C0)
                              : Colors.amber,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TelaWebViewPagamento extends StatefulWidget {
  final String url;
  final VoidCallback onSuccess;

  const TelaWebViewPagamento({super.key, required this.url, required this.onSuccess});

  @override
  State<TelaWebViewPagamento> createState() => _TelaWebViewPagamentoState();
}

class _TelaWebViewPagamentoState extends State<TelaWebViewPagamento> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
        _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) => setState(() => _loading = true),
          onPageFinished: (url) => setState(() => _loading = false),
          onNavigationRequest: (request) {
            // Aqui você pode adicionar lógica para detectar se o pagamento foi concluído 
            // baseando-se na URL de retorno (ex: mercadopago.com/success)
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pagamento'),
        actions: [
          // Como não temos uma URL de retorno garantida sem saber o provedor,
          // adicionamos um botão de "Concluí o Pagamento" para o usuário.
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              widget.onSuccess();
            },
            child: const Text('CONCLUÍDO', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}