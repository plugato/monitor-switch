#!/usr/bin/env bash
# install.sh - prepara a maquina Linux: confere ddcutil, modulo i2c-dev, permissoes do /dev/i2c-*, jq/python3,
# torna os scripts executaveis e detecta os monitores.
#   ./install.sh                 so verifica e orienta (nao usa sudo)
#   ./install.sh --autostart     tambem cria ~/.config/autostart/monitor-tray.desktop (bandeja com a sessao)
#   ./install.sh --no-autostart  remove essa entrada
#   ./install.sh --hotkeys       tambem registra os atalhos globais (GNOME) via install-hotkeys.sh
#   ./install.sh --kvm           tambem instala e liga o servico "seguir o KVM" (systemd de usuario, monitor-kvm.sh)
#   ./install.sh --no-kvm        desliga e remove o servico "seguir o KVM"
#   ./install.sh --all           autostart + hotkeys + kvm
set -u
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
chmod +x "$HERE"/*.sh 2>/dev/null
. "$HERE/ddcci.sh"

autostart=0; noautostart=0; hotkeys=0; kvm=0; nokvm=0
for a in "$@"; do
  case "$a" in
    --autostart)    autostart=1 ;;
    --no-autostart) noautostart=1 ;;
    --hotkeys)   hotkeys=1 ;;
    --kvm)       kvm=1 ;;
    --no-kvm)    nokvm=1 ;;
    --all)       autostart=1; hotkeys=1; kvm=1 ;;
    -h|--help)   sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "opcao desconhecida: $a" >&2; exit 1 ;;
  esac
done

ok()   { printf '  [ok]    %s\n' "$*"; }
warn() { printf '  [!!]    %s\n' "$*"; }
info() { printf '          %s\n' "$*"; }
problems=0

echo "monitor-input (Linux) - $(ddc_monitor_name)"
echo "config: $DDC_CONFIG"
echo

# 1. ddcutil
if command -v ddcutil >/dev/null 2>&1; then ok "ddcutil $(ddcutil --version 2>/dev/null | head -1 | awk '{print $2}')"
else
  warn 'ddcutil nao instalado'; problems=1
  if   command -v apt-get >/dev/null; then info 'sudo apt install ddcutil'
  elif command -v dnf     >/dev/null; then info 'sudo dnf install ddcutil'
  elif command -v pacman  >/dev/null; then info 'sudo pacman -S ddcutil'
  elif command -v zypper  >/dev/null; then info 'sudo zypper install ddcutil'
  else info 'instale o pacote ddcutil da sua distribuicao'; fi
fi

# 2. modulo i2c-dev (cria os /dev/i2c-*)
if ls /dev/i2c-* >/dev/null 2>&1; then ok "dispositivos I2C: $(ls /dev/i2c-* | tr '\n' ' ')"
else
  warn 'nenhum /dev/i2c-* encontrado: modulo i2c-dev nao carregado'; problems=1
  info 'agora:         sudo modprobe i2c-dev'
  info 'permanente:    echo i2c-dev | sudo tee /etc/modules-load.d/i2c-dev.conf'
fi

# 3. permissao de escrita no I2C (grupo i2c ou regra udev do ddcutil)
if ls /dev/i2c-* >/dev/null 2>&1; then
  writable=0; for d in /dev/i2c-*; do [ -w "$d" ] && writable=1; done
  if [ "$writable" = 1 ]; then ok 'usuario tem acesso aos dispositivos I2C'
  else
    warn "usuario $USER sem permissao de escrita em /dev/i2c-*"; problems=1
    if getent group i2c >/dev/null 2>&1; then
      info "sudo usermod -aG i2c $USER   (depois saia e entre de novo na sessao)"
    else
      info "sudo groupadd --system i2c && sudo usermod -aG i2c $USER"
    fi
    rules="$(ls /usr/share/ddcutil/data/*i2c*.rules 2>/dev/null | head -1)"
    [ -n "$rules" ] && info "sudo cp $rules /etc/udev/rules.d/ && sudo udevadm control --reload && sudo udevadm trigger"
    info 'ou, so para testar agora: sudo ./set-monitor-input.sh DP'
  fi
fi

# 4. leitor de JSON
if command -v jq >/dev/null 2>&1; then ok 'jq (leitura do config.json)'
elif command -v python3 >/dev/null 2>&1; then ok 'python3 (leitura do config.json; jq e opcional)'
else warn 'nem jq nem python3: config.json sera ignorado e os padroes HDMI=6 / DP=9 usados'; fi

# 5. opcionais
command -v notify-send >/dev/null 2>&1 && ok 'notify-send (notificacoes)' || info 'opcional: libnotify-bin / notify-send para notificacoes'
command -v yad         >/dev/null 2>&1 && ok 'yad (icone de bandeja)'     || info 'opcional: yad para o icone de bandeja (monitor-tray.sh)'

# 6. placa de video
if lsmod 2>/dev/null | grep -q '^nvidia '; then
  warn 'driver NVIDIA proprietario detectado: o I2C pode vir desabilitado'
  info 'se o ddcutil detect nao achar nada, veja https://www.ddcutil.com/nvidia/'
fi

# 7. monitores
echo
if command -v ddcutil >/dev/null 2>&1 && ls /dev/i2c-* >/dev/null 2>&1; then
  echo 'Monitores detectados (ddcutil detect):'
  found=0
  for d in $(ddc_displays); do
    found=1
    if r="$(ddc_getvcp "$d" 10 2>/dev/null)"; then st="responde DDC/CI (brilho ${r%% *})"; else st='NAO responde a leitura DDC/CI'; fi
    printf '  /dev/i2c-%-3s %-40s %s\n' "$d" "$(ddc_display_desc "$d")" "$st"
  done
  if [ "$found" = 0 ]; then
    warn 'nenhum display valido. DDC/CI desligado no menu do monitor, sem permissao no I2C, ou monitor em outra entrada.'
    problems=1
  fi
fi

# 8. autostart da bandeja
if [ "$autostart" = 1 ]; then
  echo
  dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"; mkdir -p "$dir"
  cat > "$dir/monitor-tray.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Monitor input (DDC/CI)
Comment=Troca de entrada do $(ddc_monitor_name) via DDC/CI
Exec=$HERE/monitor-tray.sh
Icon=video-display
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
  ok "autostart criado: $dir/monitor-tray.desktop"
  ddc_log 'autostart da bandeja: ativado'
  ddc_notify 'Iniciar com a sessao: ligado'
fi
if [ "$noautostart" = 1 ]; then
  echo
  rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/monitor-tray.desktop"
  ok 'autostart da bandeja removido'; ddc_log 'autostart da bandeja: removido'
  ddc_notify 'Iniciar com a sessao: desligado'
fi

# 9. atalhos globais
if [ "$hotkeys" = 1 ]; then
  echo
  "$HERE/install-hotkeys.sh"
fi

# 10. seguir o KVM (servico systemd de usuario; sem systemd, entrada de autostart)
SVC_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
if [ "$nokvm" = 1 ]; then
  echo
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now monitor-kvm.service 2>/dev/null
    rm -f "$SVC_DIR/monitor-kvm.service"; systemctl --user daemon-reload 2>/dev/null
  fi
  rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/monitor-kvm.desktop"
  ok 'servico "seguir o KVM" removido'; ddc_log 'seguir KVM (Linux): servico removido'
fi
if [ "$kvm" = 1 ]; then
  echo
  if ! ddc_usb_ids "$(ddc_kvm_cfg sentinel)" >/dev/null; then
    warn "kvm.sentinel invalido no config.json: '$(ddc_kvm_cfg sentinel)'. Descubra o vid:pid com lsusb."
  elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    mkdir -p "$SVC_DIR"
    cat > "$SVC_DIR/monitor-kvm.service" <<EOF
[Unit]
Description=Seguir o KVM: troca a entrada do monitor quando o teclado USB sai ou volta
After=graphical-session.target

[Service]
ExecStart=$HERE/monitor-kvm.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    if systemctl --user enable --now monitor-kvm.service; then
      ok "servico monitor-kvm.service ativo (status: systemctl --user status monitor-kvm; log: journalctl --user -u monitor-kvm)"
    else
      warn 'nao consegui ativar o servico; rode ./monitor-kvm.sh na mao para ver o erro'; problems=1
    fi
  else
    dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"; mkdir -p "$dir"
    printf '[Desktop Entry]\nType=Application\nName=Monitor KVM follower\nExec=%s/monitor-kvm.sh\nTerminal=false\nX-GNOME-Autostart-enabled=true\n' "$HERE" > "$dir/monitor-kvm.desktop"
    ok "sem systemd de usuario: autostart criado em $dir/monitor-kvm.desktop (vale a partir do proximo login)"
  fi
  ddc_log 'seguir KVM (Linux): servico instalado'
  if [ "$(ddc_kvm_cfg enabled)" != true ]; then
    warn 'kvm.enabled esta false: o servico observa mas nao troca. Ligue com ./monitor-kvm.sh --enable (ou pelo menu da bandeja).'
  fi
  "$HERE/monitor-kvm.sh" --status
fi

echo
if [ "$problems" = 0 ]; then
  echo "Tudo pronto. Teste:  $HERE/set-monitor-input.sh DP"
else
  echo 'Resolva os itens [!!] acima e rode ./install.sh de novo.'
fi
