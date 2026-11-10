# monitor-input — troca de entrada e controle do Samsung Odyssey G5 via DDC/CI

Ferramentas em PowerShell para controlar o monitor **Samsung Odyssey G5 (LC34G55T)** a partir do
Windows, sem tocar no menu físico: trocar entre **HDMI** e **DisplayPort**, ajustar brilho, contraste,
cores e outros parâmetros. Nada precisa ser instalado; usa apenas a API DDC/CI do Windows (`dxva2.dll`).

Testado em: Windows 11, Dell Precision 3591 ligado ao monitor por HDMI, monitor com firmware de fábrica.

## Início rápido

| Quero...                                  | Faça                                                                 |
|-------------------------------------------|----------------------------------------------------------------------|
| Um ícone na bandeja com HDMI / DisplayPort | duplo clique em **`MonitorTray.vbs`**                                |
| Trocar pra DisplayPort com um clique       | duplo clique em **`to-dp.cmd`** (ou atalho global **Ctrl+Alt+2**)     |
| Trocar pra HDMI                            | duplo clique em **`to-hdmi.cmd`** (ou **Ctrl+Alt+1**)                 |
| Painel completo (brilho, cor, energia...)  | duplo clique em **`MonitorControl.cmd`**                             |
| Iniciar o ícone junto com o Windows        | menu do ícone → **Iniciar com o Windows**                            |
| Usar no outro PC                           | copie a pasta inteira pra lá e rode o `MonitorTray.vbs`              |
| Usar em Linux                              | copie a pasta e rode `linux/install.sh` (ver [linux/README.md](linux/README.md)) |

Os atalhos globais só funcionam enquanto o ícone da bandeja estiver rodando.

## Como funciona

DDC/CI é um protocolo que trafega pelo próprio cabo de vídeo e permite ao PC ler e escrever
parâmetros do monitor, cada um identificado por um código VCP (padrão MCCS da VESA).
A troca de entrada é o código `0x60`.

**Regra fundamental: o comando só sai do PC que está exibindo imagem no monitor naquele momento.**
Do notebook (HDMI) você manda o monitor pro DisplayPort. Pra voltar, o comando tem que sair do PC
que está no DisplayPort. Por isso a pasta deve ser copiada para as duas máquinas.

## Descobertas sobre este monitor (importante)

Estes pontos custaram uma tarde de testes. Não presuma o comportamento padrão.

1. **Os valores de entrada são proprietários.** O padrão MCCS diz HDMI = `0x11` e DisplayPort = `0x0F`,
   e o monitor até anuncia `0x0F/0x10/0x12` na string de capabilities, mas ignora todos eles.
   Os valores que funcionam foram achados por varredura de `0x00` a `0x1F`:

   | Entrada     | Valor VCP 0x60 |
   |-------------|----------------|
   | HDMI        | `0x06` (6)     |
   | DisplayPort | `0x09` (9)     |

2. **A leitura de `0x60` é inútil.** O monitor devolve sempre `6`, independentemente da entrada ativa.
   Não dá pra saber por software em qual entrada ele está.

3. **`SetVCPFeature` sempre retorna sucesso**, mesmo quando o monitor ignora o valor. "ok" não
   significa que trocou.

4. **Se a entrada de destino não tem sinal, o monitor dorme** em poucos segundos e para de responder
   DDC/CI pela outra entrada também. Nesse estado só o botão físico traz de volta. Com o outro PC
   ligado e mandando sinal, tudo funciona nos dois sentidos.

5. **Auto Source Switch+** (menu Sistema do monitor) é um caminho alternativo: com ele ligado, cortar o
   sinal HDMI (`DisplaySwitch.exe /internal`) faz o monitor pular sozinho pro DisplayPort, e religar
   (`DisplaySwitch.exe /extend`) traz de volta. Não depende do DDC/CI.

6. **Armadilhas de PowerShell:** `$Input` é variável automática. Um parâmetro com esse nome chega vazio
   e o script envia `0x00` reportando sucesso. O projeto usa `-Source`. Nomes de função também não
   diferenciam maiúsculas: `Read-VCP` sobrescreve `Read-Vcp` do módulo. Por isso o painel usa
   `Read-Mon`/`Write-Mon` e chama o módulo com prefixo (`DdcCi\Read-Vcp`).

### Códigos VCP que respondem à leitura (varredura completa 0x00–0xFF)

| Código | Função (MCCS)                     | Observado                    |
|--------|-----------------------------------|------------------------------|
| 0x02   | New control value                 | leitura                      |
| 0x04 / 0x05 / 0x08 | Restaurar tudo / brilho-contraste / cor | escrita (ação) |
| 0x10   | Brilho                            | 0–100                        |
| 0x12   | Contraste                         | 0–100                        |
| 0x14   | Preset de cor                     | atual 2, max 5               |
| 0x16 / 0x18 / 0x1A | Ganho R / G / B           | 0–100                        |
| 0x20 / 0x30 | Posição H / V                | 0–255 (sem efeito em digital)|
| 0x60   | Entrada                           | **06=HDMI, 09=DP**; leitura fixa em 6 |
| 0x87   | Nitidez                           | 0–100                        |
| 0xAA   | Orientação                        | 1 = paisagem                 |
| 0xB0   | Salvar (1) / restaurar (2) ajustes| escrita                      |
| 0xB6   | Tipo de painel                    | 3 = LCD TFT                  |
| 0xC8 / 0xC9 | Controlador / Firmware       | leitura                      |
| 0xCC   | Idioma do OSD                     | 1–30 (14 = Português-BR)     |
| 0xD6   | Energia                           | 1 on, 4 standby, 5 off       |
| 0xDC   | Modo de imagem                    | capabilities: 00 02 03 05    |
| 0xDF   | Versão MCCS                       | 0x200                        |
| 0xE0 / 0xE1 / 0xE2 | proprietário Samsung      | atual 2, max 5 (função desconhecida) |
| 0xE5 / 0xE6 | proprietário Samsung             | liga/desliga                 |
| 0xF3 / 0xF7 / 0xFE / 0xCA / 0xDB / 0xE9 / 0xF5 | proprietário Samsung | desconhecido |

Candidatos prováveis para os proprietários em monitores Odyssey: tempo de resposta, Black Equalizer,
FreeSync, Eye Saver, Low Input Lag. Mude um valor no painel e observe o menu do monitor.

String de capabilities reportada:

```
(prot(monitor)type(lcd)SAMSUNGcmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(05 08 0B 0C) 16 18 1A 52 60( 12 0F 10) AA(01 02 03 FF) AC AE B2 B6 C6 C8 C9 D6(01 04 05) DC(00 02 03 05 ) DF FD)mccs_ver(2.1)mswhql(1))
```

## Arquivos

| Arquivo                 | Papel                                                                          |
|-------------------------|--------------------------------------------------------------------------------|
| `DdcCi.psm1`            | Módulo compartilhado: P/Invoke em `dxva2.dll`, leitura/escrita VCP, config, log, hotkeys. Tudo passa por aqui. |
| `config.json`           | Códigos de entrada, teclas de atalho, ação do duplo clique, caminho do log.     |
| `MonitorTray.ps1` / `.vbs` | Ícone de bandeja. O `.vbs` inicia sem janela de console. Segue o KVM e conversa com o outro PC. |
| `MonitorBeacon.ps1`     | Opcional: avisa o outro PC já na tela de login (tarefa agendada, instalada pelo menu da bandeja). |
| `MonitorControl.ps1` / `.cmd` | Painel completo com quatro abas.                                        |
| `Set-MonitorInput.ps1`  | Linha de comando: `-Source HDMI|DP` ou `-Raw <valor>`.                          |
| `to-dp.cmd` / `to-hdmi.cmd` | Atalhos de um clique (chamam o script acima).                              |
| `menu.cmd`              | Prompt interativo pra enviar qualquer valor em hex ao `0x60` (útil pra descobrir valores). |
| `logs\monitor.log`      | Registro de tudo que foi enviado ao monitor (rotaciona em 1 MB).               |
| `linux/`                | Versão Linux em Bash sobre o `ddcutil`, com os mesmos papéis (CLI, painel, bandeja, atalhos). Usa este mesmo `config.json`. Detalhes em `linux/README.md`. |

## Seguir o KVM (um botão troca tudo)

O KVM em uso (UGREEN, só botão físico) não aceita comando por software: ele aparece ao Windows como
hubs USB genéricos (Genesys 05E3:0610 + Terminus 1A40:0101), sem interface de controle. A hotkey de
KVMs é lida pelo próprio aparelho antes do PC, então também não dá pra simular.

A solução é reagir ao KVM em vez de comandá-lo. Ao apertar o botão, o teclado e o mouse **somem**
deste PC e o Windows emite `WM_DEVICECHANGE`. A aplicação de bandeja observa um dispositivo-sentinela
(o teclado Logitech G413, `USB\VID_046D&PID_C33A`):

- sentinela **saiu** → monitor vai para `kvm.onLeave` (DP neste notebook);
- sentinela **voltou** → monitor vai para `kvm.onArrive` (HDMI).

Liga e desliga pelo menu do ícone ("Seguir o KVM") ou por `kvm.enabled` no `config.json`.

**Rode nos dois PCs.** O comando que vale é o de quem está **saindo**: esse PC é o que o monitor está
exibindo, então o DDC/CI dele é ouvido na hora. O PC que **recebe** o teclado fala por uma entrada
inativa, que o monitor às vezes demora ou se recusa a atender — se só um PC seguir o KVM, a troca de
volta para ele fica lenta ou falha. Com os dois rodando, cada troca é feita por quem sai e confirmada
por quem chega (mesma entrada, sem conflito). Além de reagirem ao mesmo teclado, os dois conversam pela
rede local (próxima seção).

O mesmo `config.json` serve aos dois: `kvm.linux` e `kvm.windows` sobrescrevem as chaves do `kvm` em cada
sistema. Aqui o Windows está no HDMI e o Linux no DP:

```json
"kvm": { "enabled": true, "onLeave": "DP", "onArrive": "HDMI",
         "linux": { "onLeave": "HDMI", "onArrive": "DP" } }
```

**Tempo de reação.** Não há verificação periódica: o Windows avisa no instante em que o USB muda.
O atraso total é a soma de:

| Etapa | Tempo | Ajuste |
|-------|-------|--------|
| KVM desconectar o USB e o Windows perceber | ~0,5–1 s | hardware, não ajustável |
| Espera para agrupar os eventos (`kvm.delayMs`) | 400 ms (padrão) | `config.json`; abaixo de ~200 ms pode disparar duas vezes |
| Verificar se a sentinela ainda está presente | poucos ms | usa `cfgmgr32` (a versão com `Get-PnpDevice` levava ~2 s) |
| Enviar o comando ao monitor | ~50 ms | enumeração sem leitura prévia (`-NoProbe`) |
| O monitor trocar a entrada | ~1–2 s | firmware do monitor |

Se quiser reagir mais rápido, reduza `delayMs`; se perceber troca dupla, aumente. A sentinela pode ser qualquer dispositivo que esteja atrás do KVM;
descubra o prefixo com `Get-PnpDevice -PresentOnly | ? InstanceId -like 'USB\VID*'`.

### Os dois PCs conversam pela rede

Limitação do monitor: mandado para uma entrada **sem sinal** (outro PC dormindo, desligado ou fora da dock),
ele dorme e para de responder DDC/CI pelas duas entradas; só o botão físico o trazia de volta. O Auto Source
Switch+ não resolve. Por isso a bandeja do Windows e o serviço do Linux trocam mensagens UDP na rede local
(porta `peer.port`, 47321), com a regra **"o PC que tem o teclado é o dono do monitor"**:

| Situação | O que acontece |
|----------|----------------|
| Teclado sai e o outro PC está **pronto** (vivo e com o monitor conectado) | troca para o outro PC, como antes |
| Teclado sai e o outro PC **não está pronto** | o monitor **fica** neste PC; aviso "outro PC indisponível" |
| Depois disso o outro PC acorda, liga ou volta para a dock, com o teclado | o monitor vai para ele **sozinho** |
| Teclado chega | troca aqui **e** pede ao outro PC (que está na tela, e é ouvido) para trocar |
| Este PC acorda da suspensão, inicia ou tem o monitor reconectado, com o teclado nele | puxa o monitor para si |
| "Mudar para X" no menu, duplo clique ou atalho | envia aqui **e** pede ao outro PC: funciona de qualquer um dos dois |
| Nenhum monitor aceitou o comando | tenta de novo após 1,5 / 4 / 8 / 15 s |

- Cada PC manda um `hello` a cada 5 s (broadcast); "pronto" = `hello` há menos de `peer.timeoutSec` (15 s) e
  monitor conectado (no Windows: monitor externo ativo; no Linux: conector DRM `connected`). Ao suspender ou
  sair, manda `bye`.
- **Firewall:** no Windows, menu da bandeja > "Liberar a conversa com o outro PC no firewall (admin)" (regra
  de entrada UDP 47321, redes privadas). A rede do Windows precisa estar como **Privada**. No Linux, com `ufw`
  ativo: `sudo ufw allow 47321/udp`.
- Até o primeiro contato entre os dois, o comportamento antigo vale (troca sem conferir) e o log avisa
  "sem contato com o outro PC". Assim um firewall bloqueando não faz o KVM parar de trocar.
- **Notebook desligado:** a bandeja só roda depois do login. Marque no menu "Avisar o outro PC já na tela de
  login (admin)": uma tarefa agendada (SYSTEM, ao iniciar o Windows) roda o `MonitorBeacon.ps1`, que manda
  `hello` até a bandeja abrir. Ligou o notebook com o teclado nele, o monitor vai para a tela de login.
- Estado: menu da bandeja ("Outro PC: pronto / indisponível / nunca visto") ou `linux/monitor-kvm.sh --status`.

```json
"peer": { "enabled": true, "port": 47321, "host": "", "timeoutSec": 15 }
```

- `host`: IP ou nome do outro PC, se o broadcast não chegar (redes diferentes, Wi-Fi isolando clientes).
- `key`: opcional; se definida (igual nos dois), mensagens sem ela são ignoradas. Não ponha no `config.json`
  versionado de um repositório público.
- `enabled: false` volta ao comportamento antigo (sem rede).

## Configuração (`config.json`)

```json
{
  "monitor": "Samsung Odyssey G5 (LC34G55T)",
  "inputs":  { "HDMI": 6, "DP": 9 },
  "hotkeys": { "HDMI": "Ctrl+Alt+1", "DP": "Ctrl+Alt+2" },
  "doubleClick": "DP",
  "logFile": "logs\\monitor.log"
}
```

- `monitor`: nome mostrado na bandeja, nas notificações e no painel. Sem a chave, vazio ou `"auto"`, é
  detectado pelo EDID do monitor (`Samsung LC34G55T`): WMI `WmiMonitorID` no Windows, `ddcutil detect` no Linux.
- `inputs`: nome → valor do VCP 0x60. Pode adicionar entradas (ex.: `"HDMI2": 7`); o menu da bandeja e o
  painel criam um botão por item.
- `hotkeys`: modificadores `Ctrl`, `Alt`, `Shift`, `Win` mais uma tecla (`1`, `F9`, `D`...). Deixe `{}`
  pra desativar. Se a combinação já estiver em uso por outro programa, o log avisa.
- `doubleClick`: entrada enviada no duplo clique do ícone. No notebook faz sentido ser a entrada do
  *outro* PC.
- `windows` / `linux`: blocos que sobrescrevem qualquer chave acima só naquele sistema, para o mesmo
  `config.json` servir aos dois PCs. Ex.: `"linux": { "doubleClick": "HDMI" }` (no Linux, que está no DP, o
  clique leva ao notebook). `kvm.windows` / `kvm.linux` continuam valendo.

## Usar em outro computador

Pacotes prontos ficam em **Releases** no GitHub: `monitor-switch-windows-<versão>.zip` e
`monitor-switch-linux-<versão>.tar.gz` (com `"monitor": "auto"`). Para publicar uma versão nova:
`git tag v1.2.0 && git push origin v1.2.0`; o workflow `.github/workflows/release.yml` valida os scripts
e cria a release. Push e PR na `main` só rodam a validação.

### Atualização automática

A bandeja consulta a última release 1 min após iniciar e depois a cada `update.intervalHours`. Havendo versão
nova, baixa o pacote do sistema, confere o SHA-256 com o `SHA256SUMS.txt` da release, substitui os arquivos
(**`config.json` e `logs/` são preservados**) e reinicia a bandeja. Manual: menu da bandeja >
"Verificar atualizações", ou `Update-Monitor.ps1` (Windows) / `linux/update.sh` (Linux, `--check` só compara).

```json
"update": { "mode": "install", "repo": "plugato/monitor-switch", "intervalHours": 24 }
```

- `mode`: `install` (baixa e instala sozinho), `notify` (só avisa), `off`.
- Numa cópia **git** (pasta de desenvolvimento) a atualização usa `git pull --ff-only` (sem pedir senha; se o
  remoto SSH pedir chave, usa o HTTPS público do repositório). A automática só faz isso sozinha no branch `main`
  com a árvore limpa; com alteração local (inclusive no `config.json`), só avisa.

- **Windows:** copie a pasta, rode `MonitorTray.vbs`, marque "Iniciar com o Windows". Troque
  `doubleClick` pra `HDMI` se aquele PC estiver no DisplayPort.
- **Linux:** pasta `linux/`: `./install.sh` confere `ddcutil`, módulo `i2c-dev` e permissões; depois
  `./set-monitor-input.sh DP`, `./install-hotkeys.sh` (atalhos no GNOME), `./monitor-tray.sh` (bandeja)
  e `./install.sh --kvm` (seguir o KVM via `udev`, mesmo bloco `kvm` do `config.json`).
  Na mão: `ddcutil setvcp 60 0x06 --noverify` (HDMI) ou `ddcutil setvcp 60 0x09 --noverify` (DP).
- **macOS:** `m1ddc set input 6` / `m1ddc set input 9`, ou o app BetterDisplay.

## Adaptar para outro monitor

1. Rode `MonitorControl.cmd` → aba **Avançado** → "Varrer todos os códigos legíveis" e
   "Mostrar string de capabilities".
2. Tente primeiro os valores padrão de entrada (`0x0F` DP, `0x11` HDMI1, `0x12` HDMI2) pelo `menu.cmd`.
3. Se não funcionarem, varra `0x00` a `0x1F` com o outro aparelho **ligado e enviando sinal**, para ver a
   imagem trocar em vez de uma tela preta.
4. Anote os valores em `config.json` e deixe `"monitor": "auto"` para o nome vir do próprio monitor.

## Solução de problemas

| Sintoma | Causa provável | O que fazer |
|---------|----------------|-------------|
| "ok" mas não troca | valor errado pro seu monitor | ver "Adaptar para outro monitor" |
| Tela preta após trocar | entrada de destino sem sinal | com os dois PCs conversando não acontece pelo KVM; ver "Os dois PCs conversam pela rede" |
| Teclado foi pro outro PC e o monitor ficou | outro PC indisponível (dormindo, desligado, fora da dock) | é o esperado: acorde o outro PC e o monitor vai sozinho |
| Bandeja diz "Outro PC: nunca visto" | firewall, rede Pública no Windows, ou serviço parado no outro PC | menu > "Liberar ... no firewall"; rede Privada; `linux/monitor-kvm.sh --status`; `peer.host` |
| Nada responde, nem brilho | DDC/CI desligado no menu do monitor, ou monitor em outra entrada | menu Sistema → DDC/CI ligado |
| Atalho global não funciona | ícone da bandeja não está rodando, ou combinação em uso | abrir `MonitorTray.vbs`; ver `logs\monitor.log` |
| Ícone não aparece | Windows 11 esconde ícones novos | clicar na seta `^` da bandeja e arrastar o ícone pra fora |
| Arquivos `.ps1` sumiram da pasta | observado durante o desenvolvimento, causa não confirmada (Defender não registrou detecção) | restaurar do backup; manter cópia da pasta |

## Alternativas prontas

- **ControlMyMonitor** (NirSoft): `ControlMyMonitor.exe /SetValue Primary 60 9`.
- **Twinkle Tray** (Microsoft Store): `--VCP=0x60:9`.
- **Switch KVM** físico, se quiser independência total de software.

## Histórico

- 2026-09-21: valores `0x06`/`0x09` descobertos por varredura; primeira versão dos scripts, painel
  completo, ícone de bandeja, módulo compartilhado, `config.json`, atalhos globais e este README.
- 2026-09-21: versão Linux (`linux/`) em Bash sobre o `ddcutil`, reaproveitando o `config.json`.
- 2026-11-10: os dois PCs conversam pela rede (não manda o monitor para um PC indisponível; reconecta sozinho),
  retentativas, overrides `windows`/`linux` e atualização automática na cópia git.
