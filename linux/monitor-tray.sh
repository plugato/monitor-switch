#!/usr/bin/env bash
# monitor-tray.sh - icone de bandeja para trocar a entrada do monitor (equivalente de MonitorTray.ps1).
# Usa o yad (--notification). Clique esquerdo = entrada de config.doubleClick; clique direito = menu.
#   Instalar yad:  sudo apt install yad  |  sudo dnf install yad  |  sudo pacman -S yad
#   Iniciar com a sessao:  ./install.sh --autostart
# Atalhos globais nao dependem deste script no Linux: veja install-hotkeys.sh.
set -u
. "$(dirname "$(readlink -f "$0")")/ddcci.sh"
ddc_require || exit 3
if ! command -v yad >/dev/null 2>&1; then
  echo 'yad nao encontrado (necessario para o icone de bandeja). Instale: sudo apt install yad' >&2
  echo 'Alternativa sem bandeja: atalhos globais com ./install-hotkeys.sh, ou ./to-dp.sh e ./to-hdmi.sh' >&2
  exit 3
fi

# uma instancia por vez
lock="${XDG_RUNTIME_DIR:-/tmp}/monitor-tray.lock"
exec 9>"$lock"
flock -n 9 || exit 0

SET="$DDC_ROOT/set-monitor-input.sh"
CTRL="$DDC_ROOT/monitor-control.sh"

# terminal para abrir o painel
term_cmd() {
  local t
  for t in x-terminal-emulator gnome-terminal konsole xfce4-terminal kitty alacritty xterm; do
    if command -v "$t" >/dev/null 2>&1; then
      case "$t" in gnome-terminal) echo "$t -- \"$CTRL\"" ;; *) echo "$t -e \"$CTRL\"" ;; esac
      return
    fi
  done
  echo "\"$CTRL\""
}

menu=""
for n in $(ddc_input_names); do
  menu+="$(printf '%s  (0x%02X)' "$n" "$(ddc_input_value "$n")")!\"$SET\" --notify $n!video-display|"
done
menu+="Controle completo...!$(term_cmd)!preferences-desktop-display|"
menu+="Sair!quit!application-exit"

ddc_log 'bandeja iniciada'
exec yad --notification \
  --image=video-display \
  --text="$(ddc_monitor_name) - entrada (clique: $(ddc_double_click), botao direito: menu)" \
  --command="\"$SET\" --notify $(ddc_double_click)" \
  --menu="$menu"
