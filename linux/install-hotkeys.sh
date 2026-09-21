#!/usr/bin/env bash
# install-hotkeys.sh - registra os atalhos globais de config.json (ex.: Ctrl+Alt+1 -> HDMI) no ambiente grafico.
#   ./install-hotkeys.sh            registra (GNOME e derivados, via gsettings)
#   ./install-hotkeys.sh --remove   remove os atalhos criados por este script
#   ./install-hotkeys.sh --show     so mostra os comandos/atalhos, sem alterar nada (util para KDE, i3, sway...)
# No Windows os atalhos vivem dentro do MonitorTray; no Linux quem os dispara e o proprio desktop, entao
# eles funcionam mesmo sem a bandeja rodando.
set -u
. "$(dirname "$(readlink -f "$0")")/ddcci.sh"

SET="$DDC_ROOT/set-monitor-input.sh"
SCHEMA=org.gnome.settings-daemon.plugins.media-keys
BASE=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
PREFIX=monitor-input-

to_gnome() {  # 'Ctrl+Alt+1' -> '<Control><Alt>1'
  local out="" tok key="" IFS='+'
  for tok in $1; do
    tok="${tok// /}"
    case "${tok,,}" in
      ctrl|control)     out+='<Control>' ;;
      alt)              out+='<Alt>' ;;
      shift)            out+='<Shift>' ;;
      win|windows|super) out+='<Super>' ;;
      *)                key="$tok" ;;
    esac
  done
  [ -n "$key" ] || return 1
  [ "${#key}" -eq 1 ] && key="${key,,}"
  echo "$out$key"
}
to_i3() {  # 'Ctrl+Alt+1' -> 'Ctrl+Mod1+1'   (i3 / sway)
  local out="" tok key="" IFS='+'
  for tok in $1; do
    tok="${tok// /}"
    case "${tok,,}" in
      ctrl|control) out+='Ctrl+' ;; alt) out+='Mod1+' ;; shift) out+='Shift+' ;; win|windows|super) out+='Mod4+' ;;
      *) key="$tok" ;;
    esac
  done
  echo "$out$key"
}

mapfile -t NAMES < <(ddc_input_names)

show() {
  echo "Atalhos definidos em $DDC_CONFIG:"
  local n hk
  for n in "${NAMES[@]}"; do
    hk="$(ddc_hotkey "$n")"; [ -n "$hk" ] || continue
    printf '  %-12s %-14s  comando: "%s" --notify %s\n' "$n" "$hk" "$SET" "$n"
  done
  cat <<EOF

Como registrar em cada ambiente:
  GNOME / Ubuntu / Pop!_OS / Budgie:  ./install-hotkeys.sh   (automatico, via gsettings)
  KDE Plasma:  Configuracoes do Sistema > Atalhos > Atalhos personalizados > Editar > Novo > Atalho global > Comando/URL
  XFCE:        Configuracoes > Teclado > Atalhos de aplicativos > Adicionar
  i3 / sway (~/.config/i3/config ou ~/.config/sway/config):
EOF
  for n in "${NAMES[@]}"; do
    hk="$(ddc_hotkey "$n")"; [ -n "$hk" ] || continue
    printf '    bindsym %-18s exec --no-startup-id "%s" --notify %s\n' "$(to_i3 "$hk")" "$SET" "$n"
  done
  echo '  sxhkd (~/.config/sxhkd/sxhkdrc):'
  for n in "${NAMES[@]}"; do
    hk="$(ddc_hotkey "$n")"; [ -n "$hk" ] || continue
    printf '    %s\n        "%s" --notify %s\n' "$(to_i3 "$hk" | sed 's/Mod1/alt/;s/Mod4/super/;s/Ctrl/ctrl/;s/Shift/shift/;s/+/ + /g')" "$SET" "$n"
  done
}

gnome_ok() {
  command -v gsettings >/dev/null 2>&1 && gsettings list-schemas 2>/dev/null | grep -qx "$SCHEMA"
}
current_list() {  # caminhos atuais, um por linha
  gsettings get "$SCHEMA" custom-keybindings 2>/dev/null | tr -d "[]'@as" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$'
}
write_list() {  # le caminhos de stdin, grava a lista no formato ['a', 'b']
  local items="" p
  while read -r p; do [ -n "$p" ] && items+="'$p', "; done
  gsettings set "$SCHEMA" custom-keybindings "[${items%, }]"
}

install_gnome() {
  gnome_ok || { echo 'gsettings/GNOME media-keys nao encontrado neste ambiente. Use --show para instrucoes manuais.' >&2; return 1; }
  local -a keep; mapfile -t keep < <(current_list | grep -v "/${PREFIX}")
  local n hk path binding
  for n in "${NAMES[@]}"; do
    hk="$(ddc_hotkey "$n")"; [ -n "$hk" ] || continue
    binding="$(to_gnome "$hk")" || { echo "Tecla invalida em '$hk' ($n)" >&2; continue; }
    path="$BASE/${PREFIX}${n,,}/"
    gsettings set "$SCHEMA.custom-keybinding:$path" name    "Monitor -> $n"
    gsettings set "$SCHEMA.custom-keybinding:$path" command "\"$SET\" --notify $n"
    gsettings set "$SCHEMA.custom-keybinding:$path" binding "$binding"
    keep+=("$path")
    echo "  $hk  ->  $n   ($binding)"
    ddc_log "hotkey GNOME registrada: $hk -> $n"
  done
  printf '%s\n' "${keep[@]}" | write_list
  echo 'Atalhos registrados. Se algum nao responder, a combinacao ja esta em uso por outro programa (Configuracoes > Teclado).'
}

remove_gnome() {
  gnome_ok || { echo 'gsettings/GNOME media-keys nao encontrado.' >&2; return 1; }
  local p
  while read -r p; do
    case "$p" in */${PREFIX}*) gsettings reset-recursively "$SCHEMA.custom-keybinding:$p" 2>/dev/null; echo "  removido $p" ;; esac
  done < <(current_list)
  current_list | grep -v "/${PREFIX}" | write_list
  ddc_log 'hotkeys GNOME removidas'
}

case "${1:-}" in
  --show|-s)   show ;;
  --remove|-r) remove_gnome ;;
  ''|--install|-i) install_gnome || { echo; show; } ;;
  *) echo "Uso: $(basename "$0") [--install | --remove | --show]"; exit 1 ;;
esac
