const express = require('express');
const mercadopago = require('mercadopago');
const cors = require('cors');

const app = express();
app.use(cors());
app.use(express.json());
// Use variável de ambiente para o token de segurança
const ACCESS_TOKEN = process.env.ACCESS_TOKEN;
if (!ACCESS_TOKEN) {
  console.error('Erro: variável de ambiente ACCESS_TOKEN não definida.');
  process.exit(1);
}
mercadopago.configure({ access_token: ACCESS_TOKEN });

// Endpoint único para criar pagamento PIX
app.post('/criar-pix', async (req, res) => {
  const { valor, inscricaoId, nome, email } = req.body;
  if (!valor || !inscricaoId) {
    return res.status(400).json({ error: 'Valor e inscricaoId são obrigatórios.' });
  }
  try {
    const payment_data = {
      transaction_amount: Number(valor),
      description: `Pagamento inscrição ${inscricaoId}`,
      payment_method_id: 'pix',
      payer: {
        email: email || 'comprador@email.com',
        first_name: nome || undefined,
      }
    };
    const payment = await mercadopago.payment.create(payment_data);
    const pixInfo = payment.body.point_of_interaction.transaction_data;
    res.json({
      qrCodeImageUrl: pixInfo.qr_code_base64 ? `data:image/png;base64,${pixInfo.qr_code_base64}` : null,
      copiaECola: pixInfo.qr_code,
    });
  } catch (err) {
    console.error('Erro ao criar pagamento PIX:', err);
    res.status(400).json({ error: err.message });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`Backend rodando na porta ${PORT}`));