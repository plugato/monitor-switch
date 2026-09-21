#!/usr/bin/env bash
# ddcci.sh - biblioteca compartilhada de acesso DDC/CI via ddcutil (equivalente Linux de DdcCi.psm1).
# Carregada por set-monitor-input.sh, monitor-control.sh, monitor-tray.sh, menu.sh.
#   Uso:  . "$(dirname "$0")/ddcci.sh"
#   Requer: ddcutil.  Opcional: jq ou python3 (le config.json), notify-send, yad (bandeja).
# Le o mesmo config.json da versao Windows (pasta pai) ou um config.json local nesta pasta.

[ -n "${__DDCCI_LOADED:-}" ] && return 0
__DDCCI_LOADED=1

DDC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${DDC_CONFIG:-}" ] && [ -f "$DDC_CONFIG" ]; then :
elif [ -f "$DDC_ROOT/config.json" ]; then DDC_CONFIG="$DDC_ROOT/config.json"
else DDC_CONFIG="$DDC_ROOT/../config.json"; fi
DDC_BASE="$(cd "$(dirname "$DDC_CONFIG")" 2>/dev/null && pwd || echo "$DDC_ROOT")"

# ---------------------------------------------------------------- configuracao
# Mesmos padroes do DdcCi.psm1 (Samsung Odyssey G5 LC34G55T). config.json sobrescreve por chave.
_ddc_json() {  # _ddc_json get|keys chave [subchave]  -> valor ou lista de chaves (vazio se nao existir)
  local mode="$1"; shift
  [ -f "$DDC_CONFIG" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    local path="" k; for k in "$@"; do path+="[\"$k\"]"; done
    if [ "$mode" = get ]; then jq -r ".$path // empty" "$DDC_CONFIG" 2>/dev/null
    else jq -r ".$path | keys_unsorted[]" "$DDC_CONFIG" 2>/dev/null; fi
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$mode" "$DDC_CONFIG" "$@" <<'PY'
import json, sys
mode, path, keys = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    d = json.load(open(path, encoding="utf-8"))
    for k in keys: d = d[k]
except Exception:
    sys.exit(0)
if mode == "get":
    if d is None or isinstance(d, (dict, list)): sys.exit(0)
    print(str(d).lower() if isinstance(d, bool) else d)
elif isinstance(d, dict):
    print("\n".join(d.keys()))
PY
  else
    return 1
  fi
}
ddc_cfg_get()  { _ddc_json get "$@"; }
ddc_cfg_keys() { _ddc_json keys "$@"; }
ddc_cfg_available() {  # config.json existe E ha jq ou python3 para le-lo; senao valem os padroes
  [ -f "$DDC_CONFIG" ] && { command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; }
}

ddc_monitor_name() { local v; v="$(ddc_cfg_get monitor)"; echo "${v:-Samsung Odyssey G5 (LC34G55T)}"; }

ddc_input_names() {  # um nome por linha, na ordem do config.json
  local k; k="$(ddc_cfg_keys inputs)"
  if [ -n "$k" ]; then echo "$k"; else printf 'HDMI\nDP\n'; fi
}
ddc_input_value() {  # ddc_input_value DP -> 9 ; retorna 1 se desconhecida
  local v=""
  if [ -n "$(ddc_cfg_keys inputs)" ]; then v="$(ddc_cfg_get inputs "$1")"
  else case "$1" in HDMI) v=6 ;; DP) v=9 ;; esac; fi
  [ -n "$v" ] || return 1
  echo "$((v))"
}
ddc_hotkey() {  # ddc_hotkey DP -> 'Ctrl+Alt+2' (vazio se nao definida; "hotkeys": {} no config desativa)
  if [ -n "$(ddc_cfg_keys hotkeys)" ]; then ddc_cfg_get hotkeys "$1"
  elif ! ddc_cfg_available; then case "$1" in HDMI) echo 'Ctrl+Alt+1' ;; DP) echo 'Ctrl+Alt+2' ;; esac; fi
}
ddc_double_click() { local v; v="$(ddc_cfg_get doubleClick)"; echo "${v:-DP}"; }

ddc_log_file() {
  local f; f="$(ddc_cfg_get logFile)"; [ -n "$f" ] || f='logs/monitor.log'
  f="${f//\\//}"                       # logs\monitor.log (Windows) -> logs/monitor.log
  case "$f" in /*) echo "$f" ;; *) echo "$DDC_BASE/$f" ;; esac
}

# ---------------------------------------------------------------- log
ddc_log() {  # ddc_log mensagem  (rotaciona em 1 MB, nunca falha)
  local f dir size
  f="$(ddc_log_file)"; dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || return 0
  if [ -f "$f" ]; then
    size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    [ "$size" -gt 1048576 ] && mv -f "$f" "$f.old" 2>/dev/null
  fi
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$f" 2>/dev/null || true
}

ddc_notify() {  # ddc_notify texto [icone]  -> notificacao na area de trabalho, se houver notify-send
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send -a 'monitor-input' -i "${2:-video-display}" -t 1500 "$(ddc_monitor_name)" "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------- ddcutil
ddc_require() {
  if ! command -v ddcutil >/dev/null 2>&1; then
    cat >&2 <<'MSG'
ddcutil nao encontrado. Instale:
  Debian/Ubuntu:  sudo apt install ddcutil
  Fedora:         sudo dnf install ddcutil
  Arch:           sudo pacman -S ddcutil
  openSUSE:       sudo zypper install ddcutil
Depois rode ./install.sh para conferir modulo i2c-dev e permissoes.
MSG
    return 1
  fi
}

ddc_code() {  # normaliza codigo VCP para 2 digitos hex: '60', '0x60', 'x60' -> '60'
  local c="$1"
  case "$c" in 0x*|0X*|x*|X*) printf '%02X' "$((16#${c#*[xX]}))" ;; *) printf '%02X' "$((16#$c))" ;; esac
}

# Os monitores sao identificados pelo numero do barramento I2C (/dev/i2c-N) e os comandos usam '--bus N':
# '--display N' faria o ddcutil redetectar tudo a cada chamada (~1 s); '--bus' fala direto (poucos ms),
# o que importa para atalhos e para o "seguir o KVM" (equivalente do -NoProbe da versao Windows).
ddc_displays() {  # barramentos dos displays validos do 'ddcutil detect' (cache na sessao). DDC_BUS=N forca um.
  if [ -n "${DDC_BUS:-}" ]; then echo "$DDC_BUS"; return; fi
  if [ -z "${DDC_DISPLAYS:-}" ]; then
    DDC_DISPLAYS="$(ddcutil detect --terse 2>/dev/null | awk '/^Display [0-9]+/ {ok=1; next} /^Invalid/ {ok=0} ok && /I2C bus:/ {sub(/.*\/dev\/i2c-/,""); print $0; ok=0}' | tr '\n' ' ')"
  fi
  local d; for d in $DDC_DISPLAYS; do echo "$d"; done
}

ddc_display_desc() {  # ddc_display_desc BUS -> 'SAM:LC34G55T:...'
  ddcutil detect --terse 2>/dev/null | awk -v n="$1" '/I2C bus:/ {cur=$0; sub(/.*\/dev\/i2c-/,"",cur)} cur==n && /Monitor:/ {sub(/.*Monitor: */,""); print; exit}'
}

ddc_getvcp() {  # ddc_getvcp BUS CODIGO -> 'atual max tipo'  (max='-' para nao continuos). Retorna 1 se nao le.
  local d="$1" code out
  code="$(ddc_code "$2")"
  out="$(ddcutil --bus "$d" getvcp "$code" --terse 2>/dev/null)" || return 1
  _ddc_parse_terse "$out"
}
_ddc_parse_terse() {  # 'VCP 10 C 50 100' | 'VCP 14 SNC x05' | 'VCP DC CNC x00 x00 x00 x05'
  local -a f; read -ra f <<< "$1"
  [ "${f[0]:-}" = VCP ] || return 1
  case "${f[2]:-}" in
    C)        echo "${f[3]} ${f[4]} C" ;;
    SNC|CNC)  local last="${f[${#f[@]}-1]}"; echo "$((16#${last#x})) - NC" ;;
    T)        echo "${f[3]} - T" ;;
    *)        return 1 ;;
  esac
}

ddc_setvcp() {  # ddc_setvcp BUS CODIGO VALOR(dec ou 0xNN) -> 0/1, registra no log
  local d="$1" code val ok=ok
  code="$(ddc_code "$2")"; val="$(( $3 ))"
  # --noverify: este monitor devolve sempre 6 em 0x60, e a verificacao do ddcutil falharia
  ddcutil --bus "$d" setvcp "$code" "$val" --noverify >/dev/null 2>&1 || ok=FALHOU
  ddc_log "$(printf 'i2c-%s: set 0x%s <- %d (0x%02X) %s' "$d" "$code" "$val" "$val" "$ok")"
  [ "$ok" = ok ]
}

ddc_find_display() {  # primeiro display que responde a leitura de brilho (0x10), ou vazio
  local d try
  for d in $(ddc_displays); do
    for try in 1 2 3; do
      if ddc_getvcp "$d" 10 >/dev/null 2>&1; then echo "$d"; return 0; fi
      sleep 0.12
    done
  done
  return 1
}

ddc_capabilities() { ddcutil --bus "$1" capabilities 2>/dev/null; }

ddc_scan() {  # ddc_scan BUS -> linhas 'CODIGO atual max tipo' de todos os codigos que respondem
  local line parsed
  ddcutil --bus "$1" getvcp SCAN --terse 2>/dev/null | while IFS= read -r line; do
    case "$line" in VCP*) parsed="$(_ddc_parse_terse "$line")" && echo "${line:4:2} $parsed" ;; esac
  done
}

# ---------------------------------------------------------------- dispositivos USB (KVM)
# Equivalente de Test-DevicePresent: a sentinela e um dispositivo USB atras do KVM (teclado). Le /sys direto,
# sem depender de lsusb. Aceita o formato do Windows ('USB\VID_046D&PID_C33A') ou 'vid:pid' ('046d:c33a').
ddc_kvm_cfg() {  # ddc_kvm_cfg enabled|sentinel|onLeave|onArrive|delayMs -> valor do bloco "kvm" ou padrao
  local v; v="$(ddc_cfg_get kvm "$1")"
  if [ -z "$v" ]; then
    case "$1" in enabled) v=false ;; sentinel) v='USB\VID_046D&PID_C33A' ;; onLeave) v=DP ;; onArrive) v=HDMI ;; delayMs) v=400 ;; esac
  fi
  echo "$v"
}
ddc_cfg_set() {  # ddc_cfg_set chave subchave valor_json -> edita config.json no lugar (precisa de jq ou python3)
  local tmp="$DDC_CONFIG.tmp"
  if command -v jq >/dev/null 2>&1; then
    [ -f "$DDC_CONFIG" ] || echo '{}' > "$DDC_CONFIG"
    jq --indent 2 ".[\"$1\"][\"$2\"] = $3" "$DDC_CONFIG" > "$tmp" && mv -f "$tmp" "$DDC_CONFIG"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$DDC_CONFIG" "$1" "$2" "$3" <<'PY'
import json, os, sys
p, k1, k2, v = sys.argv[1:5]
d = json.load(open(p, encoding="utf-8")) if os.path.isfile(p) else {}
d.setdefault(k1, {})[k2] = json.loads(v)
with open(p, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2, ensure_ascii=False); f.write("\n")
PY
  else
    echo "Sem jq nem python3: edite $DDC_CONFIG na mao ($1.$2 = $3)" >&2; return 1
  fi
}
ddc_usb_ids() {  # 'USB\VID_046D&PID_C33A' | '046d:c33a' -> '046d c33a' ; retorna 1 se nao reconhece
  local s="${1,,}"
  if   [[ "$s" =~ vid_([0-9a-f]{4}).*pid_([0-9a-f]{4}) ]]; then echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  elif [[ "$s" =~ ^([0-9a-f]{4}):([0-9a-f]{4})$ ]];          then echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  else return 1; fi
}
ddc_device_present() {  # ddc_device_present SENTINELA -> 0 presente, 1 ausente, 2 sentinela invalida
  local ids vid pid d
  ids="$(ddc_usb_ids "$1")" || return 2
  read -r vid pid <<< "$ids"
  for d in "${DDC_SYS_USB:-/sys/bus/usb/devices}"/*/; do
    [ -f "$d/idVendor" ] || continue
    [ "$(cat "$d/idVendor" 2>/dev/null)" = "$vid" ] && [ "$(cat "$d/idProduct" 2>/dev/null)" = "$pid" ] && return 0
  done
  return 1
}

ddc_set_input() {  # ddc_set_input NOME | --raw VALOR  -> imprime quantos displays aceitaram a escrita
  # Envia para TODOS os displays sem leitura previa, como a versao Windows: funciona mesmo quando o
  # Samsung esta em outra entrada (a tela do notebook simplesmente ignora o comando).
  local label val sent=0 d
  if [ "$1" = "--raw" ]; then
    val="$(( $2 ))"; label=raw
  else
    label="$1"
    val="$(ddc_input_value "$1")" || { echo "Entrada desconhecida '$1'. Opcoes: $(ddc_input_names | paste -sd, -)" >&2; return 1; }
  fi
  for d in $(ddc_displays); do
    ddcutil --bus "$d" setvcp 60 "$val" --noverify >/dev/null 2>&1 && sent=$((sent + 1))
  done
  ddc_log "$(printf 'entrada -> %s (0x%02X) enviado a %d monitor(es)' "$label" "$val" "$sent")"
  echo "$sent"
}
