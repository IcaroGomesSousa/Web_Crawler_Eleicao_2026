# Resultados presidenciais agregados — Maranhão

Projeto local em Flask que executa `buscador.sh`, soma os votos presidenciais dos municípios do Maranhão por turno e exibe somente dois candidatos-alvo na interface. O visual é inspirado em portais institucionais de resultados eleitorais, sem copiar identidade oficial e com aviso explícito de que não é uma página do TSE.

Os apelidos personalizados solicitados aparecem como rótulos e o nome oficial encontrado nos dados é mostrado logo abaixo, para não confundir apelido com nome oficial.

## Requisitos (Debian 13)

```bash
sudo apt update
sudo apt install python3 python3-venv curl jq
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
chmod +x buscador.sh
python app.py
```

Acesse http://127.0.0.1:5000.

## Como funciona

- `buscador.sh` baixa a lista de municípios a partir da configuração do TSE e consulta o cargo de Presidente (código `1`) para cada município e turno escolhido.
- O script agrega por número de candidato e escreve TSV para o Flask.
- `app.py` filtra os registros cujo nome oficial corresponda a Lula ou Flávio Bolsonaro e apresenta os votos somados.
- A consulta completa pode demorar e falhas em arquivos municipais são emitidas como avisos. Confirme a disponibilidade e o formato dos arquivos oficiais de 2026 antes de usar os números como resultado definitivo.

## Limitações conhecidas

- Os códigos de eleição 6257 (1º turno) e 6258 (2º turno) seguem os valores que já estavam no `buscador.sh` fornecido; confirme-os no ciclo eleitoral consultado.
- A página só mostra os dois candidatos pedidos. Se os nomes oficiais no arquivo do TSE não contiverem os termos esperados, eles não aparecerão até ajustar `candidato_alvo()` em `app.py`.
- A soma depende de cada arquivo municipal estar disponível e de `vap` conter os votos de candidato. Avisos de falha podem indicar totais incompletos.
- O servidor de desenvolvimento está vinculado a `127.0.0.1`; não o exponha diretamente à internet.
.