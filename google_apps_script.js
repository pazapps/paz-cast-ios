// Google Apps Script para inserir dados na planilha de relatórios de célula
// ID da planilha: 1hRmGeYYvKyxHJw2NpLNMRAK2ThqLkUo0SwfEy12otc4
// Aba: Células

function doPost(e) {
  try {
    var data = JSON.parse(e.postData.contents);

    // Verifica se os dados necessários estão presentes
    if (!data.spreadsheetId || !data.sheetName || !data.data) {
      return ContentService
        .createTextOutput(JSON.stringify({ success: false, error: 'Dados incompletos' }))
        .setMimeType(ContentService.MimeType.JSON);
    }

    var spreadsheet = SpreadsheetApp.openById(data.spreadsheetId);
    var sheet = spreadsheet.getSheetByName(data.sheetName);

    // Se a aba não existir, cria com cabeçalhos padrão para Inscrições
    if (!sheet) {
      sheet = spreadsheet.insertSheet(data.sheetName);
      if (data.sheetName === 'Células') {
        sheet.appendRow(['Data', 'Líder', 'Membros Presentes', 'Convidados', 'Crianças', 'Ofertas', 'Supervisão', 'Observações', 'Usuário', 'Timestamp']);
      } else if (data.sheetName === 'Volts') {
        sheet.appendRow(['Timestamp', 'Nome', 'Ministério', 'Crachá', 'Cordão', 'Equipamento', 'Situação', 'Tipo']);
      } else if (data.sheetName === 'Cultos') {
        sheet.appendRow(['Data', 'Culto', 'Presentes', 'PazKids', 'Tadel', 'Usuário', 'Timestamp']);
      } else if (data.sheetName === 'Inscrições') {
        sheet.appendRow(['inscricaoId', 'nome', 'nascimento', 'celular', 'status', 'timestamp']);
      }
    }

    var rowData;
    if (data.sheetName === 'Células') {
      rowData = [
        data.data.data || '',
        data.data.lider || '',
        data.data.membros_presentes || 0,
        data.data.convidados || 0,
        data.data.criancas || 0,
        data.data.ofertas || 0,
        data.data.supervisao ? 'Sim' : 'Não',
        data.data.observacoes || '',
        data.data.user_name || '',
        new Date().toLocaleString('pt-BR')
      ];
    } else if (data.sheetName === 'Volts') {
      var itens = data.data.itens || {};
      rowData = [
        data.data.timestamp ? new Date(data.data.timestamp.seconds * 1000).toLocaleString('pt-BR') : new Date().toLocaleString('pt-BR'),
        data.data.nome || '',
        data.data.ministerio || '',
        itens.cracha ? 'Sim' : 'Não',
        itens.cordao ? 'Sim' : 'Não',
        itens.equipamento ? 'Sim' : 'Não',
        data.data.situacao || 'Em uso',
        data.data.tipo || 'checkin',
      ];
    } else if (data.sheetName === 'Cultos') {
      rowData = [
        data.data.data || '',
        data.data.culto || '',
        data.data.presentes || 0,
        data.data.pazkids || 0,
        data.data.tadel || 0,
        data.data.user_name || '',
        new Date().toLocaleString('pt-BR')
      ];
    } else if (data.sheetName === 'Inscrições') {
      rowData = [
        data.data.inscricaoId,
        data.data.nome,
        data.data.nascimento,
        data.data.celular,
        data.data.status,
        data.data.timestamp
      ];
    } else {
      return ContentService
        .createTextOutput(JSON.stringify({ success: false, error: 'Aba não suportada' }))
        .setMimeType(ContentService.MimeType.JSON);
    }

    sheet.appendRow(rowData);

    return ContentService
      .createTextOutput(JSON.stringify({ success: true, message: 'Dados inseridos com sucesso' }))
      .setMimeType(ContentService.MimeType.JSON);
  } catch (error) {
    return ContentService
      .createTextOutput(JSON.stringify({ success: false, error: error.toString() }))
      .setMimeType(ContentService.MimeType.JSON);
  }
}

// ============================================
// Função alternativa simplificada para Cultos
// ============================================
function doPostCultos(e) {
  try {
    var sheet = SpreadsheetApp.getActiveSpreadsheet().getActiveSheet();
    var data = JSON.parse(e.postData.contents);

    // Insere os dados do relatório do culto
    sheet.appendRow([
      data.data ?? '',
      data.culto ?? '',
      data.presentes ?? 0,
      data.pazkids ?? 0,
      data.tadel ?? 0,
      data.user_name ?? '',
      new Date().toLocaleString('pt-BR')
    ]);

    return ContentService.createTextOutput(
      JSON.stringify({ success: true, message: 'Relatório do culto inserido com sucesso' })
    ).setMimeType(ContentService.MimeType.JSON);
  } catch (error) {
    return ContentService.createTextOutput(
      JSON.stringify({ success: false, error: error.toString() })
    ).setMimeType(ContentService.MimeType.JSON);
  }
}

// Função de teste (opcional)
function testInsert() {
  const testData = {
    spreadsheetId: '1hRmGeYYvKyxHJw2NpLNMRAK2ThqLkUo0SwfEy12otc4',
    sheetName: 'Células',
    data: {
      data: '15/12/2024',
      lider: 'João Silva',
      membros_presentes: 10,
      convidados: 2,
      criancas: 3,
      ofertas: 150.50,
      supervisao: true,
      observacoes: 'Reunião muito boa!',
      user_name: 'Test User'
    }
  };

  return doPost({postData: {contents: JSON.stringify(testData)}});
}

// Endpoint para ler versículos da planilha
// Planilha: 1EVhDlyjpXWAyfGn6m7PEckoKhFLY-8DjfwoakmSP6qA
// Espera colunas: versiculo, referencia, ativo, ordem
function doGet(e) {
  try {
    var spreadsheetId = '1EVhDlyjpXWAyfGn6m7PEckoKhFLY-8DjfwoakmSP6qA';
    var sheetName = 'Página1'; // Altere se o nome da aba for diferente
    var sheet = SpreadsheetApp.openById(spreadsheetId).getSheetByName(sheetName);
    var data = sheet.getDataRange().getValues();
    var headers = data[0];
    var versiculos = [];
    for (var i = 1; i < data.length; i++) {
      var row = data[i];
      var obj = {};
      for (var j = 0; j < headers.length; j++) {
        obj[headers[j].toLowerCase()] = row[j];
      }
      // Filtra apenas ativos
      if (obj['ativo'] === true || obj['ativo'] === 'TRUE' || obj['ativo'] === 'Sim' || obj['ativo'] === 'sim' || obj['ativo'] === 1) {
        versiculos.push(obj);
      }
    }
    // Ordena pelo campo ordem (se existir)
    versiculos.sort(function(a, b) {
      return (a['ordem'] || 0) - (b['ordem'] || 0);
    });
    return ContentService.createTextOutput(JSON.stringify(versiculos)).setMimeType(ContentService.MimeType.JSON);
  } catch (error) {
    return ContentService.createTextOutput(JSON.stringify({success: false, error: error.toString()})).setMimeType(ContentService.MimeType.JSON);
  }
}

// ...existing code...