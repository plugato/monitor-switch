#!/usr/bin/env bash
# update.sh - atualizacao pelas Releases do GitHub (pacote monitor-switch-linux-<tag>.tar.gz).
#   ./update.sh            verifica e, se houver versao nova, instala e reinicia bandeja e servico do KVM
#   ./update.sh --check    so compara a versao instalada com a ultima release
#   ./update.sh --auto     uso da bandeja: respeita update.mode / update.intervalHours do config.json
#   --notify               tambem mostra o resultado como notificacao (menu da bandeja)
# Config (bloco "update" do config.json): mode = install (padrao) | notify | off; repo; intervalHours (24).
# Preserva config.json e logs/. Numa copia git (pasta de desenvolvimento) usa 'git pull --ff-only' em vez do
# pacote, e no modo --auto so avisa, para nunca mexer no seu trabalho sozinho.
# O pacote baixado e conferido com o SHA256SUMS.txt da mesma release antes de tocar em qualquer arquivo.
set -u
. "$(dirname "$(readlink -f "$0")")/ddcci.sh"

ROOT="$(cd "$DDC_ROOT/.." && pwd)"
REPO="$(ddc_update_cfg repo)"
MODE="$(ddc_update_cfg mode)"
HOURS="$(ddc_update_cfg intervalHours)"; [[ "$HOURS" =~ ^[0-9]+$ ]] && [ "$HOURS" -gt 0 ] || HOURS=24
STAMP="${XDG_CACHE_HOME:-$HOME/.cache}/monitor-switch/last-update-check"
notify=0

say() {  # mensagem no terminal, no log e (com --notify) na area de trabalho
  echo "$1"; ddc_log "update: $1"
  [ "$notify" = 1 ] && ddc_notify "$1" "${2:-system-software-update}"
  return 0
}
is_git() { [ -d "$ROOT/.git" ] && command -v git >/dev/null 2>&1; }

current_version() {
  if is_git; then git -C "$ROOT" describe --tags --always 2>/dev/null || echo v0.0.0
  elif [ -f "$ROOT/VERSION" ]; then head -1 "$ROOT/VERSION"
  else echo v0.0.0; fi
}
latest_tag() {  # tag da ultima release (vazio + retorno 1 se offline / sem release)
  local json
  json="$(curl -fsSL --max-time 15 -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null)" || return 1
  if command -v jq >/dev/null 2>&1; then jq -r '.tag_name // empty' <<< "$json"
  else python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name") or "")' <<< "$json" 2>/dev/null; fi
}
newer() {  # newer ATUAL ULTIMA -> 0 se ULTIMA e maior ('v1.2.0-3-gabc' conta como v1.2.0)
  local a="${1#v}" b="${2#v}"; a="${a%%-*}"; b="${b%%-*}"
  [ "$a" != "$b" ] && [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" = "$b" ]
}

restart_running() {  # reinicia o que estiver rodando desta pasta para carregar a versao nova
  command -v systemctl >/dev/null 2>&1 && systemctl --user try-restart monitor-kvm.service 2>/dev/null
  local pat="$DDC_ROOT/monitor-tray|yad --notification.*$DDC_ROOT/"
  if pgrep -f "$pat" >/dev/null 2>&1; then
    pkill -f "$pat"
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$pat" >/dev/null 2>&1 || break; sleep 0.3; done
    # sem herdar locks: 7 = desta atualizacao, 8 = laco de verificacao da bandeja anterior
    setsid -f "$DDC_ROOT/monitor-tray.sh" >/dev/null 2>&1 < /dev/null 7>&- 8>&-
  fi
}

install_release() {  # install_release TAG
  local tag="$1" tmp pkg base src
  command -v curl >/dev/null 2>&1 || { say 'curl nao encontrado: instale para atualizar' dialog-warning; return 1; }
  tmp="$(mktemp -d)"; TMPD="$tmp"; trap 'rm -rf "$TMPD"' EXIT
  pkg="monitor-switch-linux-$tag.tar.gz"
  base="https://github.com/$REPO/releases/download/$tag"
  if ! curl -fsSL --max-time 120 -o "$tmp/$pkg" "$base/$pkg" || ! curl -fsSL --max-time 30 -o "$tmp/SHA256SUMS.txt" "$base/SHA256SUMS.txt"; then
    say "falha ao baixar $pkg" dialog-warning; return 1
  fi
  if ! (cd "$tmp" && grep " $pkg\$" SHA256SUMS.txt | sha256sum -c --status); then
    say "SHA-256 de $pkg nao confere; nada foi alterado" dialog-error; return 1
  fi
  tar -xzf "$tmp/$pkg" -C "$tmp" || { say "pacote $pkg corrompido" dialog-error; return 1; }
  src="$tmp/monitor-switch-linux-$tag"
  [ -f "$src/linux/ddcci.sh" ] || { say "pacote $pkg com formato inesperado" dialog-error; return 1; }
  rm -f "$src/config.json"                                   # o config.json do usuario fica como esta
  cp -a "$src/." "$ROOT/" || { say "falha ao copiar arquivos para $ROOT" dialog-error; return 1; }
}

update_git() {
  local before after
  before="$(git -C "$ROOT" rev-parse HEAD)"
  if ! git -C "$ROOT" pull --ff-only -q 2>/dev/null; then
    say 'git pull --ff-only falhou (alteracoes locais ou branch divergente); atualize na mao' dialog-warning; return 1
  fi
  after="$(git -C "$ROOT" rev-parse HEAD)"
  [ "$before" != "$after" ]
}

main() {
  local action=now a
  for a in "$@"; do
    case "$a" in
      --check|-c) action=check ;;
      --auto)     action=auto ;;
      --now)      action=now ;;
      --notify|-n) notify=1 ;;
      -h|--help)  sed -n '2,10p' "$0"; return 0 ;;
      *) echo "Uso: $(basename "$0") [--check | --auto | --now] [--notify]" >&2; return 1 ;;
    esac
  done

  if [ "$action" = auto ]; then
    [ "$MODE" = off ] && return 0
    # no maximo uma consulta por intervalHours (a API do GitHub sem token aceita 60 por hora)
    [ -f "$STAMP" ] && [ -n "$(find "$STAMP" -mmin -$((HOURS * 60)) 2>/dev/null)" ] && return 0
    mkdir -p "$(dirname "$STAMP")" && touch "$STAMP"
    notify=1
  fi

  # uma atualizacao por vez (bandeja, timer e menu podem disparar juntos)
  exec 7>"${XDG_RUNTIME_DIR:-/tmp}/monitor-update.lock"
  flock -n 7 || { [ "$action" = auto ] || echo 'outra atualizacao ja esta em andamento'; return 0; }

  local cur latest
  cur="$(current_version)"
  if ! latest="$(latest_tag)" || [ -z "$latest" ]; then
    [ "$action" = auto ] && { ddc_log "update: sem acesso as releases de $REPO"; return 0; }
    say "nao consegui consultar as releases de $REPO (offline ou nenhuma release publicada)" dialog-warning; return 1
  fi

  if ! newer "$cur" "$latest"; then
    if [ "$action" = auto ]; then ddc_log "update: $cur ja e a versao mais recente ($latest)"; echo "$cur ja e a versao mais recente"
    else say "versao $cur ja e a mais recente ($latest)"; fi
    return 0
  fi
  if [ "$action" = check ]; then say "nova versao disponivel: $latest (instalada: $cur)"; return 0; fi
  if [ "$action" = auto ] && { [ "$MODE" = notify ] || is_git; }; then
    say "nova versao $latest disponivel (instalada: $cur). Menu da bandeja > Verificar atualizacoes"; return 0
  fi

  if is_git; then
    update_git || return 1
  else
    install_release "$latest" || return 1
  fi
  say "monitor-switch atualizado: $cur -> $(current_version)"
  restart_running
}

# chamada numa linha so: o bash ja leu tudo antes de o cp sobrescrever este arquivo durante a atualizacao
main "$@"; exit $?
