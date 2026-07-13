import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Widget que exibe a lista de check-ins ativos (iniciados mas não concluídos com checkout)
class ListaCheckinsAtivos extends StatefulWidget {
  final Function(String docId, Map<String, dynamic> data)? onCheckoutPressed;

  const ListaCheckinsAtivos({
    super.key,
    this.onCheckoutPressed,
  });

  @override
  State<ListaCheckinsAtivos> createState() => _ListaCheckinsAtivosState();
}

class _ListaCheckinsAtivosState extends State<ListaCheckinsAtivos> {
  String _formatarHora(dynamic timestamp) {
    if (timestamp == null) return 'Hora desconhecida';
    try {
      late DateTime dateTime;
      if (timestamp is Timestamp) {
        dateTime = timestamp.toDate();
      } else if (timestamp is Map && timestamp.containsKey('seconds')) {
        dateTime = DateTime.fromMillisecondsSinceEpoch(
          (timestamp['seconds'] as int) * 1000,
        );
      } else {
        return 'Hora desconhecida';
      }
      final hour = dateTime.hour.toString().padLeft(2, '0');
      final minute = dateTime.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } catch (e) {
      return 'Erro ao formatar';
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final startOfDay = DateTime(today.year, today.month, today.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('volts_checkin')
          .where('situacao', isEqualTo: 'Em uso')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          debugPrint('Erro no StreamBuilder de check-ins ativos: ${snapshot.error}');
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: Text(
                'Erro: Verifique os índices ou permissões.',
                style: TextStyle(color: Colors.red.shade300, fontSize: 11),
              ),
            ),
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: SizedBox(
                height: 30,
                width: 30,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        final docs = snapshot.data?.docs ?? [];

        // Filtra por data e ordena manualmente no cliente (evita erro de índice composto)
        final checkinsAtivos = docs
            .map((doc) => {
                  ...doc.data() as Map<String, dynamic>,
                  'id': doc.id,
                })
            .where((checkin) {
              final ts = checkin['timestamp'];
              if (ts == null) return false;
              DateTime? dt;
              if (ts is Timestamp) {
                dt = ts.toDate();
              }
              if (dt == null) return false;
              return dt.isAfter(startOfDay) && dt.isBefore(endOfDay);
            })
            .toList();

        // Ordena por timestamp crescente
        checkinsAtivos.sort((a, b) {
          final tsA = a['timestamp'] as Timestamp?;
          final tsB = b['timestamp'] as Timestamp?;
          if (tsA == null || tsB == null) return 0;
          return tsA.compareTo(tsB);
        });

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cabeçalho com título
            Row(
              children: [
                const Icon(Icons.people, color: Colors.blueAccent, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Check-ins Ativos (Hoje)',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.blueAccent.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Text(
                    '${checkinsAtivos.length}',
                    style: const TextStyle(
                      color: Colors.blueAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
              ),
              ],
            ),
            const SizedBox(height: 12),

            // Lista de check-ins
            if (checkinsAtivos.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 16),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.done_all,
                        size: 48,
                        color: Colors.green.withOpacity(0.7),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Todos já finalizaram o checkout!',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: checkinsAtivos.length,
                separatorBuilder: (context, index) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final checkin = checkinsAtivos[index];
                  final nome = checkin['nome'] ?? 'Nome não informado';
                  final ministerio = checkin['ministerio'] ?? '';
                  final hora = _formatarHora(checkin['timestamp']);
                  final itens = checkin['itens'] as Map<String, dynamic>? ?? {};

                  // Contar itens emprestados
                  int itensCount = 0;
                  final itensLabels = [];
                  if (itens['cracha'] == true) {
                    itensCount++;
                    itensLabels.add('Crachá');
                  }
                  if (itens['cordao'] == true) {
                    itensCount++;
                    itensLabels.add('Cordão');
                  }
                  if (itens['equipamento'] == true) {
                    itensCount++;
                    itensLabels.add('Equipamento');
                  }

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white12),
                      borderRadius: BorderRadius.circular(10),
                      color: Colors.white.withOpacity(0.02),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Nome e hora
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      nome,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    decoration: BoxDecoration(
                                      color: Colors.orange.withOpacity(0.2),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    child: Text(
                                      hora,
                                      style: const TextStyle(
                                        color: Colors.orange,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                ministerio,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (itensCount > 0) ...[
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: itensLabels
                                      .map(
                                        (label) => Container(
                                          decoration: BoxDecoration(
                                            color: Colors.amber.withOpacity(0.15),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          child: Text(
                                            label,
                                            style: const TextStyle(
                                              color: Colors.amber,
                                              fontSize: 10,
                                            ),
                                          ),
                                        ),
                                      )
                                      .toList(),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Botão Checkout
                        IconButton(
                          icon: const Icon(Icons.logout, color: Colors.blueAccent),
                          tooltip: 'Fazer Checkout',
                          onPressed: () {
                            if (widget.onCheckoutPressed != null) {
                              widget.onCheckoutPressed!(checkin['id'], checkin);
                            }
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
      ],
        );
      },
    );
  }
}

