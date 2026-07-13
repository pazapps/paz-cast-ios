import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'tela_editor_anotacao.dart';

class TelaMinhasAnotacoes extends StatelessWidget {
  const TelaMinhasAnotacoes({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Minhas Anotações')),
        body: const Center(child: Text('Faça login para acessar suas anotações.')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Minhas Anotações'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Nova anotação',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const TelaEditorAnotacao(),
                ),
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('usuarios')
            .doc(user.uid)
            .collection('anotacoes')
            .orderBy('criado_em', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(child: Text('Nenhuma anotação encontrada.'));
          }
          final docs = snapshot.data!.docs;
          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final docSnap = docs[index];
              final data = docSnap.data() as Map<String, dynamic>;
              final titulo = data['titulo'] ?? '';
              final texto = data['texto'] ?? '';
              return ListTile(
                title: Text(titulo.isEmpty ? '(Sem título)' : titulo),
                subtitle: Text(
                  texto,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                leading: const Icon(Icons.sticky_note_2),
                trailing: IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  tooltip: 'Excluir',
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Excluir anotação'),
                        content: const Text('Tem certeza que deseja excluir esta anotação?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancelar'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Excluir'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await docSnap.reference.delete();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Anotação excluída!')),
                      );
                    }
                  },
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => TelaEditorAnotacao(
                        notaId: docSnap.id,
                        titulo: titulo,
                        texto: texto,
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
