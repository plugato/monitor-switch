#!/usr/bin/env bash
# monitor-kvm.sh - "seguir o KVM": observa um dispositivo USB sentinela (teclado atras do KVM) e troca a
# entrada do monitor quando ele some ou volta. Equivalente do bloco "seguir o KVM" do MonitorTray.ps1.
#   sentinela SAIU   -> monitor vai para kvm.onLeave  (DP neste notebook)
#   sentinela VOLTOU -> monitor vai para kvm.onArrive (HDMI)
# Config: bloco "kvm" do config.json (sentinel, onLeave, onArrive, delayMs). 'enabled' e so informativo aqui:
# quem liga/desliga no Linux e iniciar ou nao este script (./install.sh --kvm cria um servico systemd de usuario).
#   ./monitor-kvm.sh            roda em primeiro plano (Ctrl+C para sair)
#   ./monitor-kvm.sh --status   mostra a configuracao e se a sentinela esta presente agora
#   ./monitor-kvm.sh --once     compara com o estado salvo e troca se mudou (uso em regra udev ou cron)
# Eventos vem do 'udevadm monitor' (subsistema usb). Se ele nao rodar para este usuario, faz polling a cada 2 s.
set -u
. "$(dirname "$(readlink -f "$0")")/ddcci.sh"

SENT="$(ddc_kvm_cfg sentinel)"
LEAVE="$(ddc_kvm_cfg onLeave)"
ARRIVE="$(ddc_kvm_cfg onArrive)"
DELAY_MS="$(ddc_kvm_cfg delayMs)"; [[ "$DELAY_MS" =~ ^[0-9]+$ ]] || DELAY_MS=1500
DELAY="$(awk -v ms="$DELAY_MS" 'BEGIN { printf "%.2f", ms / 1000 }')"
STATE="${XDG_RUNTIME_DIR:-/tmp}/monitor-kvm.state"

if ! ddc_usb_ids "$SENT" >/dev/null; then
  echo "Sentinela invalida em config.json (kvm.sentinel): '$SENT'." >&2
  echo "Use o formato do Windows (USB\\VID_046D&PID_C33A) ou vid:pid (046d:c33a). Descubra com: lsusb" >&2
  exit 1
fi

present_now() { if ddc_device_present "$SENT"; then echo 1; else echo 0; fi; }

status() {
  local p; p="$(present_now)"
  echo "Sentinela:  $SENT  ($(ddc_usb_ids "$SENT" | tr ' ' ':'))  -> $([ "$p" = 1 ] && echo PRESENTE || echo AUSENTE)"
  echo "Saiu   -> $LEAVE"
  echo "Voltou -> $ARRIVE"
  echo "Atraso:     ${DELAY_MS} ms      kvm.enabled no config: $(ddc_kvm_cfg enabled)"
  if command -v systemctl >/dev/null 2>&1; then
    echo "Servico:    $(systemctl --user is-active monitor-kvm.service 2>/dev/null || echo 'nao instalado')  (./install.sh --kvm)"
  fi
}

switch_to() {
  local n
  DDC_DISPLAYS=""                        # redetecta: a lista pode ter mudado com a troca
  n="$(ddc_set_input "$1")"
  if [ "${n:-0}" -gt 0 ]; then ddc_notify "Monitor -> $1 (KVM)"; else ddc_notify 'Nenhum monitor aceitou o comando (KVM)' dialog-warning; fi
}

PRESENT=""
check() {  # compara presenca atual com a anterior; se mudou, troca a entrada
  local now; now="$(present_now)"
  [ "$now" = "$PRESENT" ] && return 0
  local first=0; [ -z "$PRESENT" ] && first=1
  PRESENT="$now"
  [ "$first" = 1 ] && return 0          # primeira leitura so registra o estado
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
  --once)      ddc_require || exit 3; once; exit 0 ;;
  ''|--run)    ;;
  *) echo "Uso: $(basename "$0") [--status | --once]"; exit 1 ;;
esac

ddc_require || exit 3
check
ddc_log "KVM: sentinela $SENT $([ "$PRESENT" = 1 ] && echo presente || echo ausente); saiu->$LEAVE voltou->$ARRIVE"
echo "Seguindo o KVM (sentinela $([ "$PRESENT" = 1 ] && echo presente || echo ausente)). Ctrl+C para sair."
if ! run_udev; then
  ddc_log 'KVM: udevadm monitor indisponivel, usando polling de 2 s'
  echo 'udevadm monitor indisponivel para este usuario; usando polling a cada 2 s.'
  run_poll
fi
