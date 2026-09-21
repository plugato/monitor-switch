#!/usr/bin/env bash
# monitor-control.sh - painel de controle do monitor via DDC/CI, em modo texto (equivalente de MonitorControl.ps1).
# Secoes: entrada e imagem | cor e modo | sistema | avancado. Tudo que e enviado vai para logs/monitor.log.
set -u
. "$(dirname "$(readlink -f "$0")")/ddcci.sh"
ddc_require || exit 3

MON=""   # barramento I2C (/dev/i2c-N) do monitor em uso

# ---------------------------------------------------------------- helpers
say()  { printf '%s\n' "$*"; }
hr()   { printf -- '-%.0s' {1..70}; echo; }
pause(){ read -rp '  [Enter para continuar] ' _ || true; }
confirm() { local r; read -rp "  $1 [s/N] " r || return 1; [[ "${r,,}" =~ ^s ]]; }

find_monitor() {
  say '  Procurando monitor...'
  MON="$(ddc_find_display)" || MON=""
  if [ -n "$MON" ]; then say "  Monitor encontrado: /dev/i2c-$MON  ($(ddc_display_desc "$MON"))"
  else say '  Nenhum monitor respondeu ao DDC/CI (DDC/CI desligado no menu, ou monitor em outra entrada?)'; fi
}
need_mon() {
  [ -n "$MON" ] && ddc_getvcp "$MON" 10 >/dev/null 2>&1 && return 0
  find_monitor; [ -n "$MON" ]
}
read_mon()  { ddc_getvcp "$MON" "$1"; }                       # -> 'atual max tipo'
write_mon() {  # write_mon CODIGO VALOR DESCRICAO
  local st=ok; ddc_setvcp "$MON" "$1" "$2" || st=FALHOU
  say "  $(printf '%s  0x%s <- %d (0x%02X)  %s' "$3" "$(ddc_code "$1")" "$(( $2 ))" "$(( $2 ))" "$st")"
}

# Controle continuo (brilho, contraste...): mostra atual/max e pede novo valor.
slider() {  # slider 'Brilho' 10
  need_mon || return
  local r cur max v
  if r="$(read_mon "$2")"; then cur="${r%% *}"; max="$(cut -d' ' -f2 <<< "$r")"; else cur='?'; max=100; fi
  read -rp "  $1 (0x$2): atual $cur, max $max. Novo valor (Enter cancela): " v || return
  [ -n "$v" ] || return
  [[ "$v" =~ ^[0-9]+$ ]] || { say '  valor invalido'; return; }
  write_mon "$2" "$v" "$1"
}

# Controle de lista (preset, modo, idioma...): mostra opcoes numeradas por valor.
combo() {  # combo 'Preset de cor' 14 '1=sRGB' '2=Nativo' ...
  need_mon || return
  local label="$1" code="$2"; shift 2
  local r cur='?' opt v found=0
  r="$(read_mon "$code")" && cur="${r%% *}"
  say "  $label (0x$code) - atual: $cur"
  for opt in "$@"; do printf '    %3s (0x%02X)  %s\n' "${opt%%=*}" "${opt%%=*}" "${opt#*=}"; done
  read -rp '  Valor (Enter cancela): ' v || return
  [ -n "$v" ] || return
  [[ "$v" =~ ^[0-9]+$ ]] || { say '  valor invalido'; return; }
  write_mon "$code" "$v" "$label"
}

# ---------------------------------------------------------------- secoes
sec_input() {
  need_mon >/dev/null 2>&1 || true
  say '  Fonte de entrada (VCP 0x60 - valores proprietarios Samsung, definidos em config.json)'
  local -a names; mapfile -t names < <(ddc_input_names)
  local i=1 n
  for n in "${names[@]}"; do printf '    %d) %s  (0x%02X)\n' "$i" "$n" "$(ddc_input_value "$n")"; i=$((i+1)); done
  say '  Obs.: se a outra entrada estiver sem sinal, o monitor dorme e so volta pelo botao fisico.'
  read -rp '  Opcao (Enter cancela): ' v || return
  [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le "${#names[@]}" ] || return
  n="${names[$((v-1))]}"
  say "  Entrada -> $n: comando aceito por $(ddc_set_input "$n") monitor(es)"
}

sec_power() {
  need_mon || return
  say '  Energia (VCP 0xD6):  1) Ligar   4) Standby   5) Desligar'
  read -rp '  Opcao (Enter cancela): ' v || return
  case "$v" in
    1) write_mon D6 1 'Energia: ligar' ;;
    4) confirm 'Colocar o monitor em standby? Ele deve voltar ao receber sinal, ou pelo botao.' && write_mon D6 4 'Energia: standby' ;;
    5) confirm 'Desligar o monitor? Pode ser necessario ligar pelo botao fisico.' && write_mon D6 5 'Energia: desligar' ;;
  esac
}

sec_restore() {
  need_mon || return
  say '  1) Brilho e contraste de fabrica (0x05)   2) Cores de fabrica (0x08)'
  say '  3) TUDO de fabrica (0x04)                 4) Salvar ajustes atuais (0xB0=1)'
  read -rp '  Opcao (Enter cancela): ' v || return
  case "$v" in
    1) confirm 'Restaurar brilho e contraste de fabrica?' && write_mon 05 1 'Restaurar brilho/contraste' ;;
    2) confirm 'Restaurar cores de fabrica?' && write_mon 08 1 'Restaurar cores' ;;
    3) confirm 'Restaurar TODAS as configuracoes de fabrica? Isso apaga seus ajustes.' && write_mon 04 1 'Restaurar tudo' ;;
    4) write_mon B0 1 'Salvar ajustes' ;;
  esac
}

sec_info() {
  need_mon || return
  local -A map=( [C9]='Firmware' [C8]='Controlador' [DF]='Versao MCCS' [B6]='Tipo de painel (3=LCD TFT)'
                 [AA]='Orientacao (1=paisagem)' [D6]='Energia' [60]='Entrada (leitura sempre 6 neste modelo)'
                 [02]='New control value' [C6]='Application enable key' [CA]='0xCA' [DB]='0xDB' [E9]='0xE9' [F5]='0xF5' [FE]='0xFE' )
  local k r
  for k in C9 C8 DF B6 AA D6 60 02 C6 CA DB E9 F5 FE; do
    if r="$(read_mon "$k")"; then
      printf '  %-42s 0x%s = %s (0x%X), max %s\n' "${map[$k]}" "$k" "${r%% *}" "${r%% *}" "$(cut -d' ' -f2 <<< "$r")"
    fi
  done
}

sec_read() {
  need_mon || return
  read -rp '  Codigo (hex): ' c || return
  [[ "$c" =~ ^(0x)?[0-9a-fA-F]{1,2}$ ]] || { say '  codigo invalido'; return; }
  local r
  if r="$(read_mon "$c")"; then
    say "  Leitura 0x$(ddc_code "$c"): atual=${r%% *} ($(printf '0x%02X' "${r%% *}"))  max=$(cut -d' ' -f2 <<< "$r")  tipo=${r##* }"
  else say "  Leitura 0x$(ddc_code "$c"): monitor nao respondeu"; fi
}

sec_send() {
  need_mon || return
  say '  Cuidado: valores desconhecidos podem ter efeitos inesperados.'
  read -rp '  Codigo (hex): ' c || return
  read -rp '  Valor  (hex): ' v || return
  [[ "$c" =~ ^(0x)?[0-9a-fA-F]{1,2}$ && "$v" =~ ^(0x)?[0-9a-fA-F]{1,4}$ ]] || { say '  codigo ou valor invalido'; return; }
  write_mon "$c" "0x${v#0x}" 'Manual'
}

sec_scan() {
  need_mon || return
  say '  Varrendo 0x00-0xFF (leva ate 1 minuto)...'
  local n=0 line
  while read -r line; do
    set -- $line
    printf '    0x%s  atual=%4s (0x%02X)  max=%4s  %s\n' "$1" "$2" "$2" "$3" "$4"; n=$((n+1))
  done < <(ddc_scan "$MON")
  say "  Varredura concluida: $n codigos respondem."
}

sec_caps() {
  need_mon || return
  local caps; caps="$(ddc_capabilities "$MON")"
  if [ -n "$caps" ]; then say "$caps"; else say '  Falha ao ler capabilities'; fi
}

sec_ref() {
  cat <<'REF'
  0x04 Restaurar tudo         0x05 Restaurar brilho/contr.   0x08 Restaurar cor
  0x10 Brilho 0-100           0x12 Contraste 0-100           0x87 Nitidez 0-100
  0x14 Preset de cor          0x16/0x18/0x1A Ganho R/G/B     0x20/0x30 Posicao H/V
  0x60 Entrada: 06=HDMI 09=DisplayPort (proprietario Samsung; padrao seria 11/0F)
  0xAA Orientacao (leitura)   0xB0 1=salvar 2=restaurar       0xB6 Tipo de painel
  0xC8 Controlador            0xC9 Firmware                  0xCC Idioma OSD
  0xD6 Energia 1=on 4=standby 5=off                          0xDC Modo de imagem
  0xDF Versao MCCS            0xE0-0xFE proprietarios Samsung (desconhecidos)
  Detalhes e historico das descobertas: README.md
REF
}

# ---------------------------------------------------------------- menu principal
find_monitor
while :; do
  echo; hr
  say "  $(ddc_monitor_name) - Controle DDC/CI    monitor: ${MON:+/dev/i2c-}${MON:-nenhum}    log: $(ddc_log_file)"
  hr
  say '  ENTRADA E IMAGEM       COR E MODO                 SISTEMA              AVANCADO'
  say '   1) Trocar entrada      7) Preset de cor (0x14)   13) Energia           17) Ler codigo'
  say '   2) Brilho   (0x10)     8) Modo de imagem (0xDC)  14) Restaurar/salvar  18) Enviar codigo'
  say '   3) Contraste(0x12)     9) Idioma OSD (0xCC)      15) Informacoes       19) Varrer 0x00-0xFF'
  say '   4) Nitidez  (0x87)    10) 0xE0 / 11) 0xE1 / 12) 0xE2 (Samsung)         20) Capabilities'
  say '   5) Ganho R/G/B        21) 0xE5 / 22) 0xE6 (liga/desliga Samsung)      23) Referencia MCCS'
  say '   6) Procurar monitor    24) 0xF3 / 25) 0xF7 (Samsung)                    0) Sair'
  read -rp '  > ' op || exit 0
  echo
  case "$op" in
    1)  sec_input ;;
    2)  slider 'Brilho' 10 ;;
    3)  slider 'Contraste' 12 ;;
    4)  slider 'Nitidez' 87 ;;
    5)  say '  Os ganhos RGB so tem efeito com o preset de cor em modo personalizado.'
        slider 'Ganho R' 16; slider 'Ganho G' 18; slider 'Ganho B' 1A ;;
    6)  find_monitor ;;
    7)  combo 'Preset de cor' 14 '1=sRGB' '2=Nativo / Normal' '3=4000K' '4=5000K' '5=6500K' '6=7500K' '8=9300K' '11=Usuario 1 (custom)' '12=Usuario 2 (custom)' ;;
    8)  combo 'Modo de imagem' DC '0=Padrao' '1=Produtividade' '2=Misto' '3=Filme' '4=Usuario' '5=Jogo' ;;
    9)  combo 'Idioma do menu OSD' CC '1=Chines (trad.)' '2=Ingles' '3=Frances' '4=Alemao' '5=Italiano' '6=Japones' '7=Coreano' \
          '8=Portugues (Portugal)' '9=Russo' '10=Espanhol' '11=Sueco' '12=Turco' '13=Chines (simpl.)' '14=Portugues (Brasil)' \
          '15=Arabe' '16=Bulgaro' '17=Croata' '18=Tcheco' '19=Dinamarques' '20=Holandes' '21=Estoniano' '22=Finlandes' '23=Grego' \
          '24=Hebraico' '25=Hungaro' '26=Letao' '27=Lituano' '28=Noruegues' '29=Polones' '30=Romeno' ;;
    10) combo '0xE0 (Samsung, funcao desconhecida)' E0 '0=0' '1=1' '2=2' '3=3' '4=4' '5=5' ;;
    11) combo '0xE1 (Samsung, funcao desconhecida)' E1 '0=0' '1=1' '2=2' '3=3' '4=4' '5=5' ;;
    12) combo '0xE2 (Samsung, funcao desconhecida)' E2 '0=0' '1=1' '2=2' '3=3' '4=4' '5=5' ;;
    21) combo '0xE5 (Samsung)' E5 '0=Desligado' '1=Ligado' ;;
    22) combo '0xE6 (Samsung)' E6 '0=Desligado' '1=Ligado' ;;
    24) combo '0xF3 (Samsung, atual 1, max 2)' F3 '0=0' '1=1' '2=2' ;;
    25) combo '0xF7 (Samsung, atual 0, max 3)' F7 '0=0' '1=1' '2=2' '3=3' ;;
    13) sec_power ;;
    14) sec_restore ;;
    15) sec_info ;;
    17) sec_read ;;
    18) sec_send ;;
    19) sec_scan ;;
    20) sec_caps ;;
    23) sec_ref ;;
    0|q|s) exit 0 ;;
    *)  say '  opcao invalida' ;;
  esac
done
