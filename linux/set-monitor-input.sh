#!/usr/bin/env bash
# set-monitor-input.sh - troca a entrada do monitor via DDC/CI (linha de comando).
#   ./set-monitor-input.sh DP               nomes definidos em config.json (HDMI, DP)
#   ./set-monitor-input.sh --raw 0x09       valor direto no VCP 0x60 (hex 0xNN ou decimal)
#   ./set-monitor-input.sh --notify DP      tambem mostra notificacao (usado pela bandeja e pelos atalhos)
# Saida: 0 ok, 1 uso incorreto, 2 nenhum monitor aceitou, 3 ddcutil ausente.
set -u
. "$(dirname "$(readlink -f "$0")")/ddcci.sh"

source=""; raw=""; notify=0
usage() { echo "Uso: $(basename "$0") [--notify] <$(ddc_input_names | paste -sd'|' -)>  ou  --raw <valor>"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --source|-s) source="${2:-}"; shift 2 ;;
    --raw|-r)    raw="${2:-}";    shift 2 ;;
    --notify|-n) notify=1;        shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          echo "Opcao desconhecida: $1" >&2; usage; exit 1 ;;
    *)           source="$1"; shift ;;
  esac
done
if [ -z "$source" ] && [ -z "$raw" ]; then usage; exit 1; fi

ddc_require || exit 3

if [ -n "$raw" ]; then
  n="$(ddc_set_input --raw "$raw")" || exit 1
  label="$(printf '0x%02X' "$((raw))")"
else
  n="$(ddc_set_input "$source")" || exit 1
  label="$source"
fi

echo "Monitor -> $label  (comando aceito por $n monitor(es))"
if [ "$notify" = 1 ]; then
  if [ "$n" -gt 0 ]; then ddc_notify "Monitor -> $label"; else ddc_notify 'Nenhum monitor aceitou o comando' dialog-warning; fi
fi
[ "$n" -gt 0 ] || exit 2
