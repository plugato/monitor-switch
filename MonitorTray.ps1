<#
  MonitorTray.ps1 - icone de bandeja para trocar a entrada do monitor via DDC/CI.
  Iniciar sem janela: MonitorTray.vbs.   Codigos e atalhos: config.json.
  Menu: HDMI / DisplayPort / controle completo / iniciar com o Windows / sair.
  Duplo clique = entrada definida em config.doubleClick.  Atalhos globais = config.hotkeys.
#>
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Import-Module (Join-Path $PSScriptRoot 'DdcCi.psm1') -Force

# uma instancia por vez
$mutex = New-Object Threading.Mutex($false, 'Global\OdysseyG5TrayMutex')
if (-not $mutex.WaitOne(0)) { exit }

$Dir = $PSScriptRoot
$cfg = Get-MonitorConfig
$MonitorName = Get-MonitorName
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Odyssey G5 Tray.lnk'
$BeaconTask = 'monitor-switch beacon'

function Notify([string]$text, [string]$icon = 'Info') {
  $tray.BalloonTipTitle = $MonitorName
  $tray.BalloonTipText = $text
  $tray.BalloonTipIcon = $icon
  $tray.ShowBalloonTip(1500)
}
function Start-Later([int]$ms, [scriptblock]$action, $state) {
  # timer de uma vez so, na thread da interface (sem runspaces)
  $t = New-Object Windows.Forms.Timer
  $t.Interval = [Math]::Max($ms, 1)
  $t.Tag = @{ Action = $action; State = $state }
  $t.Add_Tick({ $this.Stop(); $tag = $this.Tag; $this.Dispose(); & $tag.Action $tag.State })
  $t.Start()
}
$script:RetryAfterMs = @(1500, 2500, 4000, 7000)   # 1,5 / 4 / 8 / 15 s apos a primeira tentativa
$script:RetryGen = 0
$script:LastSent = @{ Name = $null; At = [datetime]::MinValue }
function Switch-To([string]$name, [switch]$Tell, [switch]$Quiet, [switch]$Force) {
  <# Envia a entrada ao monitor. -Tell tambem pede ao outro PC (se o monitor estiver nele, e ele quem e ouvido).
     Sem resposta de nenhum monitor, tenta de novo algumas vezes; um comando novo cancela as retentativas.
     O mesmo comando repetido em menos de 3 s e ignorado, a nao ser com -Force (menu e atalhos). #>
  if ($Tell) { Send-Peer (New-PeerMessage switch @{ to = $name }) }
  if (-not $Force -and $script:LastSent.Name -eq $name -and ((Get-Date) - $script:LastSent.At).TotalSeconds -lt 3) { return }
  $script:RetryGen++
  Invoke-SwitchAttempt @{ Name = $name; Attempt = 0; Gen = $script:RetryGen; Quiet = [bool]$Quiet }
}
function Invoke-SwitchAttempt($s) {
  if ($s.Gen -ne $script:RetryGen) { return }
  try { $n = Set-MonitorInput -Source $s.Name } catch { Notify $_.Exception.Message 'Error'; Write-DdcLog "erro: $($_.Exception.Message)"; return }
  if ($n -gt 0) {
    $script:LastSent = @{ Name = $s.Name; At = Get-Date }
    if (-not $s.Quiet) { Notify "Monitor -> $($s.Name)" }
  } elseif ($s.Attempt -lt $script:RetryAfterMs.Count) {
    Start-Later $script:RetryAfterMs[$s.Attempt] { param($x) Invoke-SwitchAttempt $x } @{ Name = $s.Name; Attempt = $s.Attempt + 1; Gen = $s.Gen; Quiet = $s.Quiet }
  } else {
    Write-DdcLog "nenhum monitor aceitou $($s.Name) depois de $($s.Attempt + 1) tentativas"
    Notify "Nenhum monitor aceitou o comando ($($s.Name))" 'Warning'
  }
}
function Set-Startup([bool]$on) {
  if ($on) {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($StartupLnk)
    $lnk.TargetPath = 'wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $Dir 'MonitorTray.vbs') + '"'
    $lnk.WorkingDirectory = $Dir
    $lnk.Description = 'Troca de entrada do monitor via DDC/CI'
    $lnk.Save()
    Write-DdcLog 'inicializacao com o Windows: ativada'
  } elseif (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force; Write-DdcLog 'inicializacao com o Windows: removida' }
}
function New-TrayIcon {
  # monitor azul desenhado em 16x16, sem depender de arquivo .ico
  $bmp = New-Object Drawing.Bitmap 16, 16
  $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::Transparent)
  $g.FillRectangle([Drawing.Brushes]::White, 1, 2, 14, 9)
  $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(30, 144, 255))), 2, 3, 12, 7)
  $g.FillRectangle([Drawing.Brushes]::White, 6, 11, 4, 2)
  $g.FillRectangle([Drawing.Brushes]::White, 4, 13, 8, 1)
  $g.Dispose()
  [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# ---------------------------------------------------------------- bandeja e menu
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon
$tray.Text = "$MonitorName - entrada"
$tray.Visible = $true

$menu = New-Object Windows.Forms.ContextMenuStrip
$menu.Font = New-Object Drawing.Font('Segoe UI', 10)
$title = $menu.Items.Add($MonitorName); $title.Enabled = $false
$menu.Items.Add('-') | Out-Null

# um item por entrada definida em config.inputs (ordem do arquivo), com a tecla de atalho no texto
$script:HotIds = @{}
foreach ($name in $cfg.inputs.Keys) {
  $label = "Mudar para $name"
  if ($cfg.hotkeys -and $cfg.hotkeys.Contains($name)) { $label += "`t$($cfg.hotkeys[$name])" }
  $item = $menu.Items.Add($label)
  $item.Tag = $name
  $item.Add_Click({ Switch-To $this.Tag -Tell -Force })
}
$menu.Items.Add('-') | Out-Null
$miFull = $menu.Items.Add('Abrir controle completo...')
$miFull.Add_Click({ Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $Dir 'MonitorControl.ps1')`"" })
$miLog = $menu.Items.Add('Abrir log')
$miLog.Add_Click({ $f = Join-Path $Dir $cfg.logFile; if (Test-Path $f) { Start-Process notepad $f } else { Notify 'Log ainda vazio' } })
$miKvm = $menu.Items.Add('Seguir o KVM (teclado sai -> DP, volta -> HDMI)'); $miKvm.CheckOnClick = $true
$miKvm.Checked = [bool]($cfg.kvm -and $cfg.kvm.enabled)
$miKvm.Add_Click({ $script:KvmOn = $this.Checked; Write-DdcLog "seguir KVM: $($script:KvmOn)"; if ($script:KvmOn) { $script:KvmPresent = Test-DevicePresent $cfg.kvm.sentinel } })
$miStart = $menu.Items.Add('Iniciar com o Windows'); $miStart.CheckOnClick = $true
$miStart.Checked = Test-Path $StartupLnk
$miStart.Add_Click({ Set-Startup $this.Checked })
$miPeer = $menu.Items.Add('Outro PC: aguardando contato...'); $miPeer.Enabled = $false
$miFw = $menu.Items.Add('Liberar a conversa com o outro PC no firewall (admin)...')
$miFw.Add_Click({ Install-PeerFirewall })
$miBeacon = $menu.Items.Add('Avisar o outro PC ja na tela de login (admin)'); $miBeacon.CheckOnClick = $true
$miBeacon.Checked = [bool](Get-ScheduledTask -TaskName $BeaconTask -ErrorAction SilentlyContinue)
$miBeacon.Add_Click({ Set-Beacon $this.Checked })
$miUpd = $menu.Items.Add("Verificar atualizacoes ($(Get-InstalledVersion))")
$miUpd.Add_Click({ Invoke-UpdateCheck $true })
$menu.Items.Add('-') | Out-Null
$script:Quit = { Send-Peer (New-PeerMessage bye); $tray.Visible = $false; $tray.Dispose(); if ($script:hk) { $script:hk.Dispose() }; [Windows.Forms.Application]::Exit() }
$miExit = $menu.Items.Add('Sair')
$miExit.Add_Click({ & $script:Quit })
$tray.ContextMenuStrip = $menu

# clique esquerdo abre o menu; duplo clique manda para config.doubleClick
$tray.Add_MouseClick({ if ($_.Button -eq 'Left') { [Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [Reflection.BindingFlags]'NonPublic,Instance').Invoke($tray, $null) } })
$tray.Add_DoubleClick({ if ($cfg.doubleClick) { Switch-To $cfg.doubleClick -Tell -Force } })

# ---------------------------------------------------------------- atalhos globais
$script:hk = New-Object DdcCi.HotKeyWindow
$script:hk.Callback = [Action[int]]{ param($id) if ($script:HotIds.ContainsKey($id)) { Switch-To $script:HotIds[$id] -Tell -Force } }
if ($cfg.hotkeys) {
  foreach ($name in $cfg.hotkeys.Keys) {
    if (-not $cfg.inputs.Contains($name)) { continue }
    try {
      $k = ConvertTo-HotKey $cfg.hotkeys[$name]
      $id = $script:hk.Register($k.Modifiers, $k.Key)
      if ($id -gt 0) { $script:HotIds[$id] = $name; Write-DdcLog "atalho $($cfg.hotkeys[$name]) -> $name" }
      else { Write-DdcLog "atalho $($cfg.hotkeys[$name]) indisponivel (em uso por outro programa)" }
    } catch { Write-DdcLog "atalho invalido para ${name}: $($_.Exception.Message)" }
  }
}

# ---------------------------------------------------------------- seguir o KVM + outro PC
# O KVM UGREEN so tem botao fisico. Ao apertar, o teclado (sentinela) some deste PC e o Windows manda
# WM_DEVICECHANGE. Apos um pequeno atraso (varias mensagens chegam juntas), conferimos se a sentinela
# ainda esta presente e mandamos o monitor para a entrada correspondente.
# Regra com o outro PC (rede local, bloco "peer"; mesma logica do linux/monitor-kvm.py): o PC que tem o teclado
# e o dono do monitor. So mandamos o monitor para o outro PC se ele estiver pronto (vivo e com monitor); senao o
# monitor fica aqui (uma entrada sem sinal faz o monitor dormir e parar de responder) e vai sozinho quando o outro
# PC ficar pronto. Quem recebe o teclado pede a quem esta na tela para trocar.
$script:KvmOn = [bool]($cfg.kvm -and $cfg.kvm.enabled)
$script:KvmPresent = $null
$script:PeerOn = [bool]("$(Get-PeerSetting enabled)" -match '^(true|1)$')
$script:PeerPort = [int](Get-PeerSetting port)
$script:PeerTimeout = [double](Get-PeerSetting timeoutSec)
$script:Peer = @{}                       # Id, Addr, Last, Kbd, Mon, In, Bye
$script:SeenFile = Join-Path $env:LOCALAPPDATA 'monitor-switch\peer-seen'
$script:SeenEver = Test-Path $script:SeenFile
$script:Pending = $false                 # o teclado foi para o outro PC, mas o monitor ficou aqui
$script:WarnedNeverSeen = $false
$script:PeerWasReady = $false
$script:Mon = Test-MonitorAttached
$script:Udp = $null

function Test-PeerReady {
  $p = $script:Peer
  if (-not $p.Id -or $p.Bye -or -not $p.Mon) { return $false }
  ((Get-Date) - $p.Last).TotalSeconds -lt $script:PeerTimeout
}
function Send-Peer([byte[]]$bytes) {
  if (-not $script:PeerOn) { return }
  $targets = @('255.255.255.255')
  $h = [string](Get-PeerSetting host); if ($h) { $targets += $h }
  if ($script:Peer.Addr -and $targets -notcontains $script:Peer.Addr) { $targets += $script:Peer.Addr }
  $c = $script:Udp; $tmp = $null
  if (-not $c) { $tmp = New-Object Net.Sockets.UdpClient; $tmp.EnableBroadcast = $true; $c = $tmp }
  foreach ($t in $targets) { try { [void]$c.Send($bytes, $bytes.Length, $t, $script:PeerPort) } catch { } }
  if ($tmp) { $tmp.Close() }
}
function Send-Hello {
  $kbd = if ($script:KvmPresent) { 1 } else { 0 }
  $mon = if ($script:Mon) { 1 } else { 0 }
  Send-Peer (New-PeerMessage hello @{ in = [string]$cfg.kvm.onArrive; kbd = $kbd; mon = $mon })
}
function Update-KvmState {
  # compara a presenca da sentinela com a anterior e aplica a regra; chamado pelo timer do KVM e antes de
  # qualquer decisao (reivindicar, pedido do outro PC), para nao perder uma troca de teclado ainda nao vista
  if (-not ($cfg.kvm -and $cfg.kvm.sentinel)) { return }
  $now = Test-DevicePresent $cfg.kvm.sentinel
  if ($now -eq $script:KvmPresent) { return }
  $script:KvmPresent = $now
  if (-not $script:KvmOn) { return }
  if ($now) {
    $script:Pending = $false
    Write-DdcLog 'KVM: teclado voltou'
    Switch-To $cfg.kvm.onArrive -Tell
  } elseif ($script:PeerOn -and $script:SeenEver -and -not (Test-PeerReady)) {
    $script:Pending = $true
    Write-DdcLog "KVM: teclado saiu; outro PC indisponivel (dormindo, desligado ou sem monitor): monitor fica em $($cfg.kvm.onArrive)"
    Notify 'Outro PC indisponivel: o monitor fica aqui. Ele vai sozinho quando o outro PC voltar.'
  } else {
    if ($script:PeerOn -and -not $script:SeenEver -and -not $script:WarnedNeverSeen) {
      $script:WarnedNeverSeen = $true
      Write-DdcLog "aviso: sem contato com o outro PC ate agora (servico dele parado ou firewall bloqueando UDP $($script:PeerPort)?); trocando sem conferir"
    }
    $script:Pending = $false
    Write-DdcLog 'KVM: teclado saiu'
    Switch-To $cfg.kvm.onLeave
  }
  Send-Hello
}
function Invoke-Claim([string]$reason) {
  # este PC iniciou, acordou ou teve o monitor reconectado: se o teclado esta aqui, o monitor vem para ca
  Update-KvmState
  if ($script:KvmOn -and $script:KvmPresent) {
    Write-DdcLog "$reason com o teclado aqui: monitor -> $($cfg.kvm.onArrive)"
    Switch-To $cfg.kvm.onArrive -Tell -Quiet:($reason -eq 'inicio')
  }
}
function Receive-PeerMessage([byte[]]$data, [string]$addr) {
  $m = ConvertFrom-PeerMessage $data
  if (-not $m) { return }
  $wasReady = Test-PeerReady; $wasKbd = [bool]$script:Peer.Kbd; $known = [bool]$script:Peer.Id
  if ($m.t -eq 'switch') {
    Update-KvmState
    $to = [string]$m.to
    if ($script:KvmPresent -and $to -ne [string]$cfg.kvm.onArrive) { Write-DdcLog "pedido do outro PC para $to ignorado: o teclado esta aqui"; return }
    Write-DdcLog "pedido do outro PC: monitor -> $to"
    Switch-To $to
    return
  }
  if ($m.t -ne 'hello' -and $m.t -ne 'bye') { return }
  if ($script:Peer.Id -ne $m.id) { $script:Peer = @{ Id = $m.id } }
  $script:Peer.Addr = $addr; $script:Peer.Last = Get-Date; $script:Peer.Bye = ($m.t -eq 'bye')
  if ($m.t -eq 'hello') { $script:Peer.Kbd = [bool]$m.kbd; $script:Peer.Mon = [bool]$m.mon; $script:Peer.In = [string]$m.in }
  if (-not $script:SeenEver) {
    $script:SeenEver = $true
    try { New-Item -ItemType Directory -Force -Path (Split-Path $script:SeenFile) | Out-Null; Set-Content $script:SeenFile (Get-Date -Format s) } catch { }
  }
  if (-not $known -or -not $wasReady) { Send-Hello }            # responde logo para o outro lado nao esperar 5 s
  $ready = Test-PeerReady
  if ($ready -and (-not $wasReady -or ($script:Peer.Kbd -and -not $wasKbd -and $script:Pending))) {
    Write-DdcLog "outro PC $($script:Peer.Id) pronto ($addr)"
    Update-KvmState
    if ($script:KvmOn -and $script:KvmPresent -eq $false -and ($script:Pending -or $script:Peer.Kbd)) {
      $script:Pending = $false
      Write-DdcLog "outro PC pronto com o teclado: monitor -> $($cfg.kvm.onLeave)"
      Switch-To $cfg.kvm.onLeave
    }
  } elseif ($wasReady -and -not $ready) {
    Write-DdcLog "outro PC $($script:Peer.Id) indisponivel ($(if ($script:Peer.Bye) { 'bye' } else { 'sem monitor' }))"
  }
  $script:PeerWasReady = $ready
}
function Update-PeerLabel {
  $p = $script:Peer
  $miPeer.Text = if (-not $script:PeerOn) { 'Outro PC: rede desligada (peer.enabled)' }
    elseif (-not $p.Id) { if ($script:SeenEver) { 'Outro PC: sem contato (dormindo ou desligado)' } else { 'Outro PC: nunca visto (firewall?)' } }
    elseif (Test-PeerReady) { "Outro PC: pronto ($($p.Id.Split('/')[0]), $($p.Addr))" }
    else { "Outro PC: indisponivel ($($p.Id.Split('/')[0]))" }
}
function Invoke-Elevated([string]$command, [string]$what) {
  try {
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $proc = Start-Process powershell -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc
    if ($proc.ExitCode -eq 0) { Write-DdcLog "${what}: ok"; return $true }
    Write-DdcLog "${what}: falhou (codigo $($proc.ExitCode))"
  } catch { Write-DdcLog "${what}: cancelado ($($_.Exception.Message))" }
  Notify "$what nao foi feito" 'Warning'; $false
}
function Install-PeerFirewall {
  $cmd = "Remove-NetFirewallRule -DisplayName 'monitor-switch (UDP $($script:PeerPort))' -ErrorAction SilentlyContinue; " +
         "New-NetFirewallRule -DisplayName 'monitor-switch (UDP $($script:PeerPort))' -Direction Inbound -Protocol UDP -LocalPort $($script:PeerPort) -Action Allow -Profile Private,Domain | Out-Null"
  if (Invoke-Elevated $cmd 'firewall') { Notify "Firewall liberado (UDP $($script:PeerPort), redes privadas)" }
}
function Set-Beacon([bool]$on) {
  # tarefa agendada como SYSTEM ao iniciar o Windows: avisa o outro PC (so 'hello') ate a bandeja abrir, para
  # o monitor vir para a tela de login quando este PC liga com o teclado nele
  if ($on) {
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $Dir 'MonitorBeacon.ps1')`""
    $cmd = "`$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '$($arg -replace "'", "''")'; " +
           "`$t = New-ScheduledTaskTrigger -AtStartup; " +
           "`$p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest; " +
           "`$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero); " +
           "Register-ScheduledTask -TaskName '$BeaconTask' -Action `$a -Trigger `$t -Principal `$p -Settings `$s -Force | Out-Null"
  } else {
    $cmd = "Unregister-ScheduledTask -TaskName '$BeaconTask' -Confirm:`$false -ErrorAction SilentlyContinue"
  }
  $ok = Invoke-Elevated $cmd "aviso na tela de login: $(if ($on) { 'instalar' } else { 'remover' })"
  $miBeacon.Checked = [bool](Get-ScheduledTask -TaskName $BeaconTask -ErrorAction SilentlyContinue)
  if ($ok -and $on) { Notify 'O outro PC sera avisado ja na tela de login' }
}

if ($cfg.kvm -and $cfg.kvm.sentinel) {
  $script:KvmPresent = Test-DevicePresent $cfg.kvm.sentinel
  Write-DdcLog ("KVM: sentinela {0} {1}; seguir={2}; rede={3}" -f $cfg.kvm.sentinel, $(if ($script:KvmPresent) { 'presente' } else { 'ausente' }), $script:KvmOn, $(if ($script:PeerOn) { "UDP $($script:PeerPort)" } else { 'desligada' }))
  $kvmTimer = New-Object Windows.Forms.Timer
  $kvmTimer.Interval = [int]$(if ($cfg.kvm.delayMs) { $cfg.kvm.delayMs } else { 1500 })
  $kvmTimer.Add_Tick({ $kvmTimer.Stop(); Update-KvmState })
  $script:hk.DeviceChanged = [Action]{ $kvmTimer.Stop(); $kvmTimer.Start() }
}

if ($script:PeerOn) {
  try {
    $script:Udp = New-Object Net.Sockets.UdpClient
    $script:Udp.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $script:Udp.Client.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, $script:PeerPort)))
    $script:Udp.EnableBroadcast = $true
  } catch {
    Write-DdcLog "rede: nao consegui abrir UDP $($script:PeerPort) ($($_.Exception.Message)); seguindo sem o outro PC"
    $script:Udp = $null
  }
  # leitura sem threads: um timer confere a fila do socket
  $udpTimer = New-Object Windows.Forms.Timer
  $udpTimer.Interval = 200
  $udpTimer.Add_Tick({
    if (-not $script:Udp) { return }
    try {
      while ($script:Udp.Available -gt 0) {
        $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
        $data = $script:Udp.Receive([ref]$ep)
        Receive-PeerMessage $data $ep.Address.ToString()
      }
    } catch { }
  })
  $udpTimer.Start()
  # a cada segundo: prazo do outro PC; a cada 5 s: hello; a cada 30 s: monitor conectado (WMI)
  $script:PeerTicks = 0
  $peerTimer = New-Object Windows.Forms.Timer
  $peerTimer.Interval = 1000
  $peerTimer.Add_Tick({
    $script:PeerTicks++
    $ready = Test-PeerReady
    if ($script:PeerWasReady -and -not $ready) { Write-DdcLog "outro PC $($script:Peer.Id) sem resposta ha $($script:PeerTimeout) s" }
    $script:PeerWasReady = $ready
    if ($script:PeerTicks % 30 -eq 0) { Update-MonitorAttached }
    if ($script:PeerTicks % 5 -eq 0) { Send-Hello }
    Update-PeerLabel
  })
  $peerTimer.Start()
  Send-Hello
}
function Update-MonitorAttached {
  $m = Test-MonitorAttached
  if ($m -eq $script:Mon) { return }
  $script:Mon = $m
  Write-DdcLog "monitor $(if ($m) { 'conectado' } else { 'desconectado' }) neste PC"
  Send-Hello
  if ($m) { Start-Later 3000 { Invoke-Claim 'monitor reconectado' } $null }
}
$script:hk.DisplayChanged = [Action]{ Start-Later 2000 { Update-MonitorAttached } $null }
$script:hk.PowerChanged = [Action[int]]{
  param($ev)
  if ($ev -eq 4) { Write-DdcLog 'suspendendo'; Send-Peer (New-PeerMessage bye) }                       # PBT_APMSUSPEND
  elseif ($ev -eq 0x12) { Write-DdcLog 'voltou da suspensao'; Start-Later 3000 { Update-MonitorAttached; Send-Hello; Invoke-Claim 'voltou da suspensao' } $null }  # PBT_APMRESUMEAUTOMATIC
}
Start-Later 3000 { Invoke-Claim 'inicio' } $null

# ---------------------------------------------------------------- atualizacao automatica
# Consulta a ultima release 1 min apos iniciar e depois a cada update.intervalHours. Para instalar, a bandeja
# abre o Update-Monitor.ps1 e fecha; ele espera este processo sair, copia os arquivos e abre a bandeja de novo.
function Invoke-UpdateCheck([bool]$manual) {
  $mode = Get-UpdateSetting mode
  if (-not $manual -and $mode -eq 'off') { return }
  $cur = Get-InstalledVersion
  try { $latest = Get-LatestRelease } catch {
    Write-DdcLog "update: sem acesso as releases: $($_.Exception.Message)"
    if ($manual) { Notify 'Nao consegui consultar as releases no GitHub' 'Warning' }
    return
  }
  if (-not (Test-NewerVersion $cur $latest)) {
    Write-DdcLog "update: $cur ja e a versao mais recente ($latest)"
    if ($manual) { Notify "Versao $cur ja e a mais recente" }
    return
  }
  # numa copia git (pasta de desenvolvimento) o automatico so faz 'git pull' com a arvore limpa no main, como no Linux
  if ($manual -or ($mode -eq 'install' -and (-not (Test-GitCheckout) -or (Test-GitCleanMain)))) {
    Write-DdcLog "update: instalando $latest (instalada: $cur)"
    Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
      '-File', "`"$(Join-Path $Dir 'Update-Monitor.ps1')`"", '-Tag', $latest, '-WaitPid', $PID, '-Restart'
    & $script:Quit
  } else {
    Notify "Nova versao $latest disponivel (instalada: $cur). Menu > Verificar atualizacoes"
  }
}
$updTimer = New-Object Windows.Forms.Timer
$updTimer.Interval = 60000
$updTimer.Add_Tick({
  $h = 24; try { $h = [Math]::Min([Math]::Max([int](Get-UpdateSetting intervalHours), 1), 500) } catch { }
  $updTimer.Interval = $h * 3600000
  Invoke-UpdateCheck $false
})
$updTimer.Start()

# resultado de uma atualizacao feita pelo Update-Monitor.ps1 antes de reabrir a bandeja
$marker = Join-Path $env:TEMP 'monitor-switch-updated.txt'
if (Test-Path $marker) {
  $msg = (Get-Content $marker -Raw).Trim(); Remove-Item $marker -Force -ErrorAction SilentlyContinue
  Notify $msg $(if ($msg -like 'Falha*') { 'Warning' } else { 'Info' })
}

Write-DdcLog 'tray iniciado'
[Windows.Forms.Application]::Run()
$mutex.ReleaseMutex()
