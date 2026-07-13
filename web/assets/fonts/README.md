Coloque aqui os arquivos de fonte que o projeto web deve servir offline.

Recomendações:
- Você pode usar `Roboto-Regular.ttf` e `Roboto-Medium.ttf` diretamente.
- Se quiser melhores tempos de carregamento, use `Roboto-Regular.woff2` e `Roboto-Medium.woff2`.
- Nomeie os arquivos exatamente como `Roboto-Regular.ttf`, `Roboto-Medium.ttf`, `Roboto-Regular.woff2` e `Roboto-Medium.woff2`, ou ajuste as referências em `web/index.html`.

Links exatos para os arquivos TTF no GitHub:
- https://github.com/google/fonts/raw/main/apache/roboto/Roboto-Regular.ttf
- https://github.com/google/fonts/raw/main/apache/roboto/Roboto-Medium.ttf

Exemplo de comando PowerShell para baixar localmente:

```powershell
New-Item -ItemType Directory -Force -Path .\web\assets\fonts\
Invoke-WebRequest -Uri "https://github.com/google/fonts/raw/main/apache/roboto/Roboto-Regular.ttf" -OutFile "web/assets/fonts/Roboto-Regular.ttf"
Invoke-WebRequest -Uri "https://github.com/google/fonts/raw/main/apache/roboto/Roboto-Medium.ttf" -OutFile "web/assets/fonts/Roboto-Medium.ttf"
```

Se você autorizar, posso tentar novamente baixar automaticamente as fontes e colocá-las aqui.
