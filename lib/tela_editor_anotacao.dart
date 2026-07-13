import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

// Permite edição de nota existente
class TelaEditorAnotacao extends StatefulWidget {
  final String? notaId;
  final String? titulo;
  final String? texto;
  const TelaEditorAnotacao({super.key, this.notaId, this.titulo, this.texto});

  @override
  State<TelaEditorAnotacao> createState() => _TelaEditorAnotacaoState();
}

class _TelaEditorAnotacaoState extends State<TelaEditorAnotacao> {
  late TextEditingController _tituloController;
  late TextEditingController _textoController;

  @override
  void initState() {
    super.initState();
    _tituloController = TextEditingController(text: widget.titulo ?? '');
    _textoController = TextEditingController(text: widget.texto ?? '');
  }

  @override
  void dispose() {
    _tituloController.dispose();
    _textoController.dispose();
    super.dispose();
  }

  Future<void> _salvarNota({bool silent = false}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Faça login para salvar a nota.')),
        );
      }
      return;
    }
    final titulo = _tituloController.text.trim();
    final texto = _textoController.text.trim();
    if (titulo.isEmpty && texto.isEmpty) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Digite algo para salvar.')),
        );
      }
      return;
    }
    try {
      final ref = FirebaseFirestore.instance
          .collection('usuarios')
          .doc(user.uid)
          .collection('anotacoes');
      if (widget.notaId != null) {
        await ref.doc(widget.notaId).update({
          'titulo': titulo,
          'texto': texto,
        });
        if (!silent) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Nota atualizada!')),
          );
          Navigator.pop(context);
        }
      } else {
        if (!silent) {
          // Só cria novo documento se for um salvamento manual (botão check)
          await ref.add({
            'titulo': titulo,
            'texto': texto,
            'criado_em': FieldValue.serverTimestamp(),
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Nota salva!')),
          );
          Navigator.pop(context);
        }
        // Se for auto-save e não tem notaId, não faz nada
      }
    } catch (e) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao salvar: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.notaId != null ? 'Editar Anotação' : 'Nova Anotação'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _salvarNota,
            tooltip: 'Salvar',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _tituloController,
              decoration: const InputDecoration(
                hintText: 'Título',
                border: InputBorder.none,
                hintStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              onChanged: (_) {
                if (widget.notaId != null) {
                  _salvarNota(silent: true);
                }
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TextField(
                controller: _textoController,
                decoration: const InputDecoration(
                  hintText: 'Digite sua anotação...',
                  border: InputBorder.none,
                ),
                maxLines: null,
                expands: true,
                onChanged: (_) {
                  if (widget.notaId != null) {
                    _salvarNota(silent: true);
                  }
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                IconButton(
                  icon: const Icon(Icons.check_box_outlined),
                  onPressed: () {},
                  tooltip: 'Checklist (visual)',
                ),
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: () {},
                  tooltip: 'Anexar arquivo (visual)',
                ),
                IconButton(
                  icon: const Icon(Icons.format_color_text),
                  onPressed: () {},
                  tooltip: 'Texto (visual)',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
