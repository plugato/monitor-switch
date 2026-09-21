#!/usr/bin/env bash
# menu.sh - prompt interativo para enviar qualquer valor em hex ao VCP 0x60 (util para descobrir valores).
# Equivalente de menu.cmd.
set -u
. "$(dirname "$(readlink -f "$0")")/ddcci.sh"
ddc_require || exit 3

while :; do
  echo
  echo "  Valores deste $(ddc_monitor_name) (config.json): $(for n in $(ddc_input_names); do printf ' %02X=%s ' "$(ddc_input_value "$n")" "$n"; done)"
  echo '  Padrao MCCS (nao funciona neste modelo):        0F=DP  11=HDMI1  12=HDMI2'
  echo '  Digite o valor em hex (ex: 09), ou "s" para sair.'
  read -rp ' > ' v || exit 0
  case "${v,,}" in
    s|q|sair) exit 0 ;;
    '') continue ;;
  esac
  if ! [[ "$v" =~ ^(0x)?[0-9a-fA-F]{1,2}$ ]]; then echo '  valor invalido'; continue; fi
  "$DDC_ROOT/set-monitor-input.sh" --raw "0x${v#0x}"
done
