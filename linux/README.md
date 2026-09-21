# monitor-input — versão Linux

Equivalentes em Bash dos scripts PowerShell da pasta pai, usando o **ddcutil** no lugar da `dxva2.dll`.
Lê o **mesmo `config.json`** da raiz do projeto (códigos de entrada, atalhos, ação do clique, log), então
basta copiar a pasta inteira do projeto para o PC Linux.

Tudo que o README principal diz sobre o monitor continua valendo aqui: valores proprietários
`0x06` (HDMI) / `0x09` (DisplayPort), leitura de `0x60` inútil, "ok" não significa que trocou, e o comando
só sai do PC que está exibindo imagem no monitor naquele momento.

## Início rápido

```bash
cd linux
./install.sh              # confere ddcutil, módulo i2c-dev, permissões e detecta o monitor
./set-monitor-input.sh DP # troca pra DisplayPort
./to-hdmi.sh              # troca pra HDMI (com notificação)
```

| Quero...                                   | Faça                                                        |
|--------------------------------------------|-------------------------------------------------------------|
| Trocar pra DisplayPort / HDMI              | `./to-dp.sh` / `./to-hdmi.sh` ou `./set-monitor-input.sh DP` |
| Atalhos globais (Ctrl+Alt+1 / Ctrl+Alt+2)  | `./install-hotkeys.sh` (GNOME) ou `--show` para outros ambientes |
| Ícone na bandeja                           | `./monitor-tray.sh` (precisa do `yad`)                      |
| Iniciar a bandeja com a sessão             | `./install.sh --autostart`                                  |
| Painel completo (brilho, cor, energia...)  | `./monitor-control.sh`                                      |
| Enviar valor hex ao `0x60` pra descobrir   | `./menu.sh`                                                 |
| Seguir o KVM (botão do KVM troca o monitor) | `./install.sh --kvm` (serviço) ou `./monitor-kvm.sh` (primeiro plano) |

## Pré-requisitos

| Pacote                | Papel                                  | Obrigatório |
|-----------------------|----------------------------------------|-------------|
| `ddcutil`             | fala DDC/CI pelo barramento I2C        | sim         |
| módulo `i2c-dev`      | expõe `/dev/i2c-*`                     | sim         |
| `jq` **ou** `python3` | leitura do `config.json`               | um dos dois (sem eles, usa HDMI=6 / DP=9) |
| `libnotify` (`notify-send`) | notificação ao trocar            | não         |
| `yad`                 | ícone de bandeja                       | só pro tray |

Permissão: o usuário precisa escrever em `/dev/i2c-*`. O `install.sh` mostra o comando certo
(`sudo usermod -aG i2c $USER` ou a regra udev que vem com o ddcutil). Sem isso, só funciona com `sudo`.

**NVIDIA proprietário:** o I2C pode vir desabilitado; veja https://www.ddcutil.com/nvidia/.

## Arquivos

| Arquivo                 | Equivalente Windows      | Papel                                                        |
|-------------------------|--------------------------|--------------------------------------------------------------|
| `ddcci.sh`              | `DdcCi.psm1`             | Biblioteca: config, log, `ddc_getvcp`, `ddc_setvcp`, `ddc_set_input`, detecção de displays |
| `set-monitor-input.sh`  | `Set-MonitorInput.ps1`   | CLI: `<nome>`, `--raw <valor>`, `--notify`                    |
| `to-dp.sh` / `to-hdmi.sh` | `to-dp.cmd` / `to-hdmi.cmd` | Um clique                                              |
| `menu.sh`               | `menu.cmd`               | Prompt hex pro `0x60`                                        |
| `monitor-control.sh`    | `MonitorControl.ps1`     | Painel em modo texto com as mesmas seções                    |
| `monitor-tray.sh`       | `MonitorTray.ps1/.vbs`   | Bandeja via `yad`                                            |
| `install-hotkeys.sh`    | hotkeys do `MonitorTray` | Registra `config.hotkeys` no GNOME; imprime config para KDE/XFCE/i3/sway/sxhkd |
| `monitor-kvm.sh`        | "Seguir o KVM" do `MonitorTray` | Observa a sentinela USB via `udevadm monitor` e troca a entrada quando ela sai/volta; `--enable`/`--disable`/`--status` |
| `install.sh`            | —                        | Diagnóstico de ambiente, autostart, hotkeys, serviço do KVM  |

O log vai para o mesmo `logs/monitor.log` da raiz (o caminho `logs\monitor.log` do `config.json` é convertido).

## Seguir o KVM

Mesma ideia da versão Windows: o KVM não aceita comando, então reagimos a ele. Quando o botão é apertado,
o teclado atrás do KVM (sentinela `kvm.sentinel`) some deste PC; o `monitor-kvm.sh` percebe pelo
`udevadm monitor` e manda o monitor para `kvm.onLeave`. Quando o teclado volta, manda `kvm.onArrive`.

- A sentinela é lida de `/sys/bus/usb/devices`, aceitando o formato do Windows
  (`USB\VID_046D&PID_C33A`) ou `vid:pid` (`046d:c33a`). Descubra o seu com `lsusb`.
- `kvm.delayMs` (400 ms) agrupa a rajada de eventos de uma troca (várias interfaces USB somem juntas).
  Abaixo de ~200 ms pode disparar duas vezes.
- `kvm.enabled` funciona como no Windows: com `false` o serviço continua observando mas não troca nada.
  O valor é relido a cada evento, então `./monitor-kvm.sh --enable` / `--disable` (ou o item do menu da
  bandeja) valem na hora. Isso edita o `config.json` e precisa de `jq` ou `python3`.
- O serviço em si é instalado com `./install.sh --kvm` e removido com `--no-kvm` (systemd de usuário,
  `monitor-kvm.service`; sem systemd de usuário, cai numa entrada de autostart).
- `./monitor-kvm.sh --status` mostra a configuração, se está ligado e se a sentinela está presente agora.
- Tempo de reação: o `udev` avisa no instante da mudança; soma-se `delayMs`, a leitura de `/sys` (ms) e o
  envio pelo barramento (ms). O resto é o hardware do KVM (~0,5–1 s) e o firmware do monitor (~1–2 s).
- Se o `udevadm monitor` não rodar para o usuário (algumas distros restringem), o script faz polling a cada 2 s.
- No outro PC, inverta `onLeave`/`onArrive`, como no Windows.

Limitação herdada do monitor: se o outro PC estiver desligado, o monitor vai para uma entrada sem sinal
e dorme; o comando de volta é enviado mas não é ouvido. Use o botão do monitor.

## Diferenças em relação ao Windows

- **Atalhos globais** são do desktop, não da bandeja. Funcionam mesmo sem o `monitor-tray.sh` rodando.
  Se a combinação já estiver em uso, o GNOME simplesmente não dispara; troque em `config.json` e rode
  `./install-hotkeys.sh` de novo.
- **Bandeja:** clique esquerdo executa `config.doubleClick` (não há duplo clique no `yad`); botão direito abre o
  menu, com os mesmos itens do Windows: uma entrada por linha (com o atalho), controle completo, abrir log,
  seguir o KVM, iniciar com a sessão, sair. O `yad` não tem item com marcador, então "seguir o KVM" e
  "iniciar com a sessão" aparecem como pares ligar/desligar.
- **Escrita sem verificação:** o `ddcutil setvcp` é chamado com `--noverify`, porque a releitura de `0x60`
  devolve sempre `6` e a verificação falharia.
- **Velocidade:** os monitores são endereçados pelo barramento I2C (`--bus N`), não por `--display N`, que
  faria o `ddcutil` redetectar tudo a cada chamada (~1 s). É o equivalente do `-NoProbe` do Windows. Só o
  `ddcutil detect` inicial custa ~1 s; o serviço do KVM faz isso uma vez na partida.
- **Varredura de códigos** usa `ddcutil getvcp SCAN`, mais lenta que no Windows (até 1 minuto).
- Para mandar em um barramento específico: `DDC_BUS=4 ./set-monitor-input.sh DP` (o número vem de
  `./install.sh` ou `ddcutil detect`). Por padrão envia a todos, como a versão Windows.
- Para usar outro arquivo de configuração: `DDC_CONFIG=/caminho/config.json ./set-monitor-input.sh DP`.

## Solução de problemas

| Sintoma                                  | O que fazer                                                            |
|------------------------------------------|------------------------------------------------------------------------|
| `ddcutil detect` não lista nada          | `sudo modprobe i2c-dev`; DDC/CI ligado no menu do monitor; driver NVIDIA (link acima) |
| `Permission denied` em `/dev/i2c-*`      | grupo `i2c` + relogar, ou regra udev; `./install.sh` mostra o comando   |
| "aceito por 0 monitor(es)"               | nenhum display válido; rode `./install.sh` e veja a lista               |
| "ok" mas não troca                       | valor errado pro seu monitor; varra com `./menu.sh` (ver README principal) |
| Tela preta após trocar                   | entrada de destino sem sinal; ligar o outro PC; voltar pelo botão       |
| Atalho não dispara                       | `./install-hotkeys.sh --show`; combinação em uso; sessão não é GNOME    |
| KVM não troca                            | `./monitor-kvm.sh --status`: ligado? sentinela certa (`lsusb`)? serviço ativo? sem `jq`/`python3` o `enabled` vale `false` |
