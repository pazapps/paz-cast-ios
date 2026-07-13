const functions = require('firebase-functions');
const admin = require('firebase-admin');
const { google } = require('googleapis');

admin.initializeApp();

// 1. COLE O ID DA SUA PLANILHA AQUI (Fica na URL entre /d/ e /edit)
const SPREADSHEET_ID = '1hRmGeYYvKyxHJw2NpLNMRAK2ThqLkUo0SwfEy12otc4';

// 2. COLE OS DADOS DO SEU ARQUIVO JSON AQUI
const serviceAccount = {
    "project_id": "pazcastanhal-809cd",
    "client_email": "sheets-sync@pazcastanhal-809cd.iam.gserviceaccount.com",
    "private_key": process.env.FIREBASE_PRIVATE_KEY
};

const auth = new google.auth.JWT(
    serviceAccount.client_email,
    null,
    serviceAccount.private_key,
    ['https://www.googleapis.com/auth/spreadsheets']
);
const sheets = google.sheets({ version: 'v4', auth });

// FUNÇÃO PARA RELATÓRIOS DE CÉLULA
exports.syncRelatorioToSheets = functions.firestore
    .document('relatorios_celula/{reportId}')
    .onCreate(async (snap, context) => {
        const data = snap.data();
        
        // Prepara a linha exatamente com os nomes que usamos no App v43.0
        const row = [
            new Date().toLocaleString('pt-BR'), // A: Data
            data.celula || "",                 // B: Nome da Célula
            data.lider || "",                  // C: Líder
            data.enviadoPor || "",             // D: Responsável pelo Envio
            data.presenca || 0,                // E: Membros
            data.convidados || 0,              // F: Convidados
            data.oferta || "0.00",             // G: Oferta
            data.supervisao || "Não",          // H: Supervisão
            data.observacoes || ""             // I: Observações
        ];

        try {
            await sheets.spreadsheets.values.append({
                spreadsheetId: SPREADSHEET_ID,
                range: 'Página1!A:I', // Verifique se o nome da aba é exatamente este
                valueInputOption: 'USER_ENTERED',
                resource: { values: [row] },
            });
            console.log('Sucesso: Relatório enviado para a planilha.');
        } catch (err) {
            console.error('ERRO AO ENVIAR PARA PLANILHA:', err.message);
        }
        return null;
    });

// FUNÇÃO DE NOTIFICAÇÃO PUSH (Mantida)
exports.enviarNotificacaoAviso = functions.firestore
    .document('avisos/{avisoId}')
    .onCreate(async (snap, context) => {
        const dados = snap.data();
        const mensagem = {
            notification: { title: dados.titulo, body: dados.descricao },
            topic: 'todos',
        };
        return admin.messaging().send(mensagem);
    });

// FUNÇÃO PARA RESET MENSAL DO DESAFIO DA BÍBLIA
exports.monthlyBibleChallengeReset = functions.pubsub.schedule('0 0 1 * *').timeZone('America/Sao_Paulo').onRun(async (context) => {
    const db = admin.firestore();
    
    // Calcular mês anterior
    const now = new Date();
    const prevMonth = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    const prevMKey = `${prevMonth.getFullYear()}-${prevMonth.getMonth() + 1}`;
    
    console.log(`Archiving Bible challenge data for month: ${prevMKey}`);
    
    // Buscar dados do mês anterior
    const rankingRef = db.collection('ranking');
    const snapshot = await rankingRef.where('month', '==', prevMKey).get();
    
    if (!snapshot.empty) {
        const batch = db.batch();
        snapshot.docs.forEach(doc => {
            // Arquivar em ranking_archive
            const archiveRef = db.collection('ranking_archive').doc();
            batch.set(archiveRef, { 
                ...doc.data(), 
                archivedAt: admin.firestore.FieldValue.serverTimestamp(),
                archiveMonth: prevMKey
            });
        });
        await batch.commit();
        console.log(`Archived ${snapshot.docs.length} records for month ${prevMKey}`);
    } else {
        console.log(`No records to archive for month ${prevMKey}`);
    }
    
    // Não precisa deletar, pois o novo mês terá nova chave mKey
    return null;
});