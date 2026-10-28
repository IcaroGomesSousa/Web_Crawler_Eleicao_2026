#!/usr/bin/env bash
set -Eeuo pipefail

# Consulta resultados oficiais do TSE para os municípios do Maranhão.
# Requisitos: Bash 4.3+, curl e jq.

readonly DEFAULT_BASE_URL="https://resultados.tse.jus.br/oficial"
readonly DEFAULT_YEAR="2026"
readonly DEFAULT_UF="ma"
readonly DEFAULT_LIMIT="10"

BASE_URL="${TSE_RESULTS_BASE_URL:-$DEFAULT_BASE_URL}"
YEAR="${TSE_RESULTS_YEAR:-$DEFAULT_YEAR}"
UF="${TSE_RESULTS_UF:-$DEFAULT_UF}"
LIMIT="${TSE_RESULTS_LIMIT:-$DEFAULT_LIMIT}"
MUNICIPIO="todos"
TURNO="1"
COLOR_MODE="${TSE_RESULTS_COLOR:-auto}"

usage() {
  cat <<'USAGE'
Uso: buscador.sh [opções]

Opções:
  -m, --municipio VALOR  Código TSE (5 dígitos), nome ou "todos" (padrão)
  -t, --turno TURNO      1, 2 ou ambos (padrão: 1)
  -l, --limite N         Candidatos por cargo/município (padrão: 10)
  -h, --help             Exibe esta ajuda

Variáveis de ambiente:
  TSE_RESULTS_YEAR=2026
  TSE_RESULTS_UF=ma
  TSE_RESULTS_BASE_URL=https://resultados.tse.jus.br/oficial
  TSE_RESULTS_LIMIT=10
  TSE_RESULTS_COLOR=auto|always|never

Exemplos:
  ./buscador.sh
  ./buscador.sh --municipio 07242 --turno 1
  ./buscador.sh --municipio Imperatriz --turno ambos
  ./buscador.sh --turno 2 --limite 5

A consulta de todos os municípios pode gerar bastante saída e requisições.
O 2º turno só consulta cargos que possuem disputa de segundo turno.
USAGE
}

die() { printf 'Erro: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    -m|--municipio) (($# >= 2)) || die "faltou valor para $1"; MUNICIPIO="$2"; shift 2 ;;
    -t|--turno) (($# >= 2)) || die "faltou valor para $1"; TURNO="${2,,}"; shift 2 ;;
    -l|--limite) (($# >= 2)) || die "faltou valor para $1"; LIMIT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; (($# == 0)) || die "argumentos inesperados: $*" ;;
    *) die "opção desconhecida: $1 (use --help)" ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "curl não encontrado. Instale o pacote curl."
command -v jq >/dev/null 2>&1 || die "jq não encontrado. Instale o pacote jq."
[[ "$UF" =~ ^[[:alpha:]]{2}$ ]] || die "TSE_RESULTS_UF deve conter duas letras."
[[ "$YEAR" =~ ^[0-9]{4}$ ]] || die "TSE_RESULTS_YEAR deve conter quatro dígitos."
[[ "$LIMIT" =~ ^[1-9][0-9]*$ ]] || die "o limite deve ser um inteiro positivo."
[[ "$TURNO" =~ ^(1|2|ambos)$ ]] || die "turno inválido: use 1, 2 ou ambos."
[[ "$COLOR_MODE" =~ ^(auto|always|never)$ ]] || die "TSE_RESULTS_COLOR deve ser auto, always ou never."
[[ "$MUNICIPIO" == todos || "$MUNICIPIO" =~ ^[0-9]{5}$ || -n "$MUNICIPIO" ]] || die "município inválido."

UF="${UF,,}"
BASE_URL="${BASE_URL%/}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

USE_COLOR=false
if [[ "$COLOR_MODE" == always ]] || { [[ "$COLOR_MODE" == auto && -t 1 && "${TERM:-dumb}" != dumb && ! -v NO_COLOR ]]; }; then
  USE_COLOR=true
fi

fetch_json() {
  local url="$1" destination="$2" description="$3"
  if ! curl --fail --silent --show-error --location \
    --retry 2 --retry-connrefused --connect-timeout 10 --max-time 30 \
    --output "$destination" "$url"; then
    printf 'Aviso: não foi possível consultar %s.\n' "$description" >&2
    return 1
  fi
  if ! jq -e 'type == "object"' "$destination" >/dev/null 2>&1; then
    printf 'Aviso: resposta JSON inválida para %s.\n' "$description" >&2
    return 1
  fi
}

# As configurações do TSE usam a lista abr (abrangências) e mu (municípios).
load_municipalities() {
  local election="$1" config="$TMP_DIR/municipios.json"
  local url="$BASE_URL/ele$YEAR/$election/config/mun-e$(printf '%06d' "$election")-cm.json"
  fetch_json "$url" "$config" "lista de municípios" || die "não foi possível obter a lista de municípios do TSE."

  jq -er --arg uf "$UF" '
    .abr[]? | select(((.cd // .sg // "") | ascii_downcase) == $uf) | .mu[]?
    | select((.cd // "") != "" and (.nm // "") != "")
    | [(.cd | tostring), .nm] | @tsv
  ' "$config" >"$TMP_DIR/municipios.tsv" || die "a lista de municípios não contém a UF '$UF' ou possui formato inesperado."
  [[ -s "$TMP_DIR/municipios.tsv" ]] || die "nenhum município encontrado para '$UF'."
}

select_municipalities() {
  local code name query
  if [[ "$MUNICIPIO" == todos ]]; then
    cat "$TMP_DIR/municipios.tsv"
    return
  fi
  if [[ "$MUNICIPIO" =~ ^[0-9]{5}$ ]]; then
    awk -F '\t' -v wanted="$MUNICIPIO" '$1 == wanted' "$TMP_DIR/municipios.tsv"
  else
    query="$(printf '%s' "$MUNICIPIO" | tr '[:upper:]' '[:lower:]')"
    awk -F '\t' -v wanted="$query" 'tolower($2) == wanted' "$TMP_DIR/municipios.tsv"
  fi
}

# Códigos oficiais das eleições gerais de 2026 por turno e esfera.
election_for_cargo() {
  local cargo="$1" turno="$2"
  case "$turno:$cargo" in
    1:1|1:6) printf '6257' ;; # eleição federal, 1º turno
    1:3|1:5|1:7) printf '6259' ;; # eleição estadual, 1º turno
    2:1) printf '6258' ;; # eleição federal, 2º turno
    2:3) printf '6260' ;; # eleição estadual, 2º turno
    *) return 1 ;;
  esac
}

cargo_name() {
  case "$1" in
    1) printf 'Presidente' ;;
    3) printf 'Governador' ;;
    5) printf 'Senador' ;;
    6) printf 'Deputado Federal' ;;
    7) printf 'Deputado Estadual' ;;
    *) printf 'Cargo %s' "$1" ;;
  esac
}

print_results() {
  local json="$1" cargo="$2" municipality="$3" turn="$4" limit="$5"
  local result_file="$TMP_DIR/result.tsv" rows=0
  jq -r --arg cargo "$cargo" --argjson limit "$limit" '
    [ .carg[]? | select((.cd // "") == $cargo)
      | .. | objects | .cand? // empty | .[]
      | select((.nmu // .nm // "") != "" and (.n // "") != "")
      | {
          nome: ((.nmu // .nm) | gsub("[[:cntrl:]]"; " ")),
          numero: .n,
          votos: (try ((.vap // "0" | tostring) | gsub("\\."; "") | tonumber) catch 0),
          eleito: ((((.e // "") | tostring | ascii_upcase) == "S") or (((.nv // "") | tostring | ascii_upcase) | contains("ELEITO")))
        }
    ] | unique_by(.numero)
      | sort_by([-.votos, (.nome | ascii_downcase), .numero])
      | .[:$limit][]
      | [.nome, .numero, (.votos | tostring), (if .eleito then "SIM" else "-" end)] | @tsv
  ' "$json" >"$result_file" || { printf 'Aviso: estrutura de candidatos inesperada.\n' >&2; return 1; }
  rows="$(wc -l < "$result_file")"
  printf '\n%s — %s — %s turno\n' "$municipality" "$(cargo_name "$cargo")" "$turn"
  if (( rows == 0 )); then
    printf '  Nenhum resultado de candidato disponível para este cargo.\n'
    return 0
  fi
  printf '%-34s %8s %12s %10s\n' 'CANDIDATO' 'NÚMERO' 'VOTOS' 'ELEITO?'
  printf '%-34s %8s %12s %10s\n' '----------------------------------' '--------' '------------' '----------'
  while IFS=$'\t' read -r name number votes elected; do
    if [[ "$elected" == SIM && "$USE_COLOR" == true ]]; then
      printf '\033[32m%-34.34s %8s %12s %10s\033[0m\n' "$name" "$number" "$votes" "$elected"
    else
      printf '%-34.34s %8s %12s %10s\n' "$name" "$number" "$votes" "$elected"
    fi
  done <"$result_file"
  printf '  ELEITO? = SIM indica candidato marcado como eleito nos dados do TSE.\n'
}

# Para 2026, a configuração de municípios é consultada pelo código federal.
load_municipalities 6257
if ! select_municipalities >"$TMP_DIR/selecionados.tsv"; then
  die "falha ao selecionar municípios."
fi
[[ -s "$TMP_DIR/selecionados.tsv" ]] || die "município '$MUNICIPIO' não encontrado em '$UF'."

municipality_count="$(wc -l < "$TMP_DIR/selecionados.tsv")"
printf 'Resultados do TSE | Eleições %s | UF: %s | Municípios: %s\n' "$YEAR" "${UF^^}" "$municipality_count"

turns=(1)
[[ "$TURNO" == 2 ]] && turns=(2)
[[ "$TURNO" == ambos ]] && turns=(1 2)

while IFS=$'\t' read -r municipality_code municipality_name; do
  for turn in "${turns[@]}"; do
    for cargo in 1 3 5 6 7; do
      election=""
      election="$(election_for_cargo "$cargo" "$turn")" || continue
      printf -v cargo_padded '%04d' "$cargo"
      printf -v election_padded '%06d' "$election"
      printf -v municipality_padded '%05d' "$((10#$municipality_code))"
      file="$TMP_DIR/resultado.json"
      url="$BASE_URL/ele$YEAR/$election/dados/$UF/${UF}${municipality_padded}-c${cargo_padded}-e${election_padded}-u.json"
      if fetch_json "$url" "$file" "$municipality_name / $(cargo_name "$cargo") / ${turn}º turno"; then
        if jq -e '.carg | type == "array"' "$file" >/dev/null 2>&1; then
          print_results "$file" "$cargo" "$municipality_name" "$turn" "$LIMIT" || true
        else
          printf 'Aviso: formato de resultado inesperado para %s (%sº turno).\n' "$municipality_name" "$turn" >&2
        fi
      fi
    done
  done
done <"$TMP_DIR/selecionados.tsv"
