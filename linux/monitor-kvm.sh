#!/usr/bin/env bash
# monitor-kvm.sh - "seguir o KVM": observa um dispositivo USB sentinela (teclado atras do KVM) e troca a
# entrada do monitor quando ele some ou volta. Equivalente do bloco "seguir o KVM" do MonitorTray.ps1.
#   sentinela SAIU   -> monitor vai para kvm.onLeave  (DP neste notebook)
#   sentinela VOLTOU -> monitor vai para kvm.onArrive (HDMI)
# Config: bloco "kvm" do config.json (enabled, sentinel, onLeave, onArrive, delayMs). Como no Windows,
# 'enabled' liga/desliga a troca: com false o script continua observando mas nao envia nada. O valor e
# relido a cada evento, entao --enable/--disable valem na hora, sem reiniciar o servico.
#   ./monitor-kvm.sh            roda em primeiro plano (Ctrl+C para sair); ./install.sh --kvm cria o servico
#   ./monitor-kvm.sh --status   mostra a configuracao e se a sentinela esta presente agora
#   ./monitor-kvm.sh --enable | --disable   grava kvm.enabled no config.json (menu da bandeja usa isto)
#   ./monitor-kvm.sh --once     compara com o estado salvo e troca se mudou (uso em regra udev ou cron)
# Eventos vem do 'udevadm monitor' (subsistema usb). Se ele nao rodar para este usuario, faz polling a cada 2 s.
set -u
. "$(dirname "$(readlink -f "$0")")/ddcci.sh"

SENT="$(ddc_kvm_cfg sentinel)"
LEAVE="$(ddc_kvm_cfg onLeave)"
ARRIVE="$(ddc_kvm_cfg onArrive)"
DELAY_MS="$(ddc_kvm_cfg delayMs)"; [[ "$DELAY_MS" =~ ^[0-9]+$ ]] || DELAY_MS=400
DELAY="$(awk -v ms="$DELAY_MS" 'BEGIN { printf "%.2f", ms / 1000 }')"
STATE="${XDG_RUNTIME_DIR:-/tmp}/monitor-kvm.state"

enabled() { [ "$(ddc_kvm_cfg enabled)" = true ]; }
present_now() { if ddc_device_present "$SENT"; then echo 1; else echo 0; fi; }

set_enabled() {  # set_enabled true|false
  if ddc_cfg_set kvm enabled "$1"; then
    ddc_log "seguir KVM: $1"
    if [ "$1" = true ]; then ddc_notify 'Seguir o KVM: ligado'; else ddc_notify 'Seguir o KVM: desligado'; fi
    echo "kvm.enabled = $1"
  else
    ddc_notify 'Nao consegui gravar config.json (falta jq ou python3)' dialog-warning; exit 1
  fi
}

status() {
  local p; p="$(present_now)"
  ddc_usb_ids "$SENT" >/dev/null && ids="($(ddc_usb_ids "$SENT" | tr ' ' ':'))" || ids='(INVALIDA)'
  echo "Seguir KVM: $(enabled && echo LIGADO || echo desligado)  (kvm.enabled no config.json)"
  echo "Sentinela:  $SENT $ids -> $([ "$p" = 1 ] && echo PRESENTE || echo AUSENTE)"
  echo "Saiu   -> $LEAVE"
  echo "Voltou -> $ARRIVE"
  echo "Atraso:     ${DELAY_MS} ms"
  if command -v systemctl >/dev/null 2>&1; then
    echo "Servico:    $(systemctl --user is-active monitor-kvm.service 2>/dev/null || echo 'nao instalado')  (./install.sh --kvm)"
  fi
  ddc_cfg_available || echo 'Aviso: sem jq/python3 o config.json nao e lido e kvm.enabled vale false.'
}

switch_to() {
  # a lista de barramentos fica em cache no processo (detectada uma vez, na partida); so redetecta se
  # nenhum monitor aceitar, o que indica que a topologia mudou. Assim a troca leva poucos ms.
  local n
  n="$(ddc_set_input "$1")"
  if [ "${n:-0}" -eq 0 ]; then DDC_DISPLAYS=""; ddc_displays >/dev/null; n="$(ddc_set_input "$1")"; fi
  if [ "${n:-0}" -gt 0 ]; then ddc_notify "Monitor -> $1 (KVM)"; else ddc_notify 'Nenhum monitor aceitou o comando (KVM)' dialog-warning; fi
}

PRESENT=""
check() {  # compara presenca atual com a anterior; se mudou (e kvm.enabled), troca a entrada
  local now; now="$(present_now)"
  [ "$now" = "$PRESENT" ] && return 0
  local first=0; [ -z "$PRESENT" ] && first=1
  PRESENT="$now"
  [ "$first" = 1 ] && return 0          # primeira leitura so registra o estado
  if ! enabled; then ddc_log "KVM: teclado $([ "$now" = 1 ] && echo voltou || echo saiu) (ignorado: kvm.enabled=false)"; return 0; fi
  if [ "$now" = 1 ]; then ddc_log 'KVM: teclado voltou'; switch_to "$ARRIVE"
  else                    ddc_log 'KVM: teclado saiu';   switch_to "$LEAVE"; fi
}

once() {
  [ -f "$STATE" ] && PRESENT="$(cat "$STATE" 2>/dev/null)"
  check
  echo "$PRESENT" > "$STATE" 2>/dev/null || true
}

run_udev() {  # retorna quando o udevadm morrer (ou nao existir)
  command -v udevadm >/dev/null 2>&1 || return 1
  local line
  while IFS= read -r line; do
    while IFS= read -r -t "$DELAY" line; do :; done   # agrupa a rajada de eventos de uma troca
    check
  done < <(udevadm monitor --udev --subsystem-match=usb 2>/dev/null)
  return 1
}
run_poll() { while :; do sleep 2; check; done; }

case "${1:-}" in
  --status|-s) status; exit 0 ;;
  --enable)    set_enabled true;  exit 0 ;;
  --disable)   set_enabled false; exit 0 ;;
  --toggle)    if enabled; then set_enabled false; else set_enabled true; fi; exit 0 ;;
  --once)      ;;
  ''|--run)    ;;
  *) echo "Uso: $(basename "$0") [--status | --enable | --disable | --toggle | --once]"; exit 1 ;;
esac

if ! ddc_usb_ids "$SENT" >/dev/null; then
  echo "Sentinela invalida em config.json (kvm.sentinel): '$SENT'." >&2
  echo "Use o formato do Windows (USB\\VID_046D&PID_C33A) ou vid:pid (046d:c33a). Descubra com: lsusb" >&2
  exit 1
fi
ddc_require || exit 3
[ "${1:-}" = --once ] && { once; exit 0; }

ddc_displays >/dev/null                  # preenche o cache de barramentos ja na partida
check
ddc_log "KVM: sentinela $SENT $([ "$PRESENT" = 1 ] && echo presente || echo ausente); seguir=$(ddc_kvm_cfg enabled); saiu->$LEAVE voltou->$ARRIVE"
echo "Seguindo o KVM (sentinela $([ "$PRESENT" = 1 ] && echo presente || echo ausente); kvm.enabled=$(ddc_kvm_cfg enabled)). Ctrl+C para sair."
if ! run_udev; then
  ddc_log 'KVM: udevadm monitor indisponivel, usando polling de 2 s'
  echo 'udevadm monitor indisponivel para este usuario; usando polling a cada 2 s.'
  run_poll
fi
