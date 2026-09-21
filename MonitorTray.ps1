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
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Odyssey G5 Tray.lnk'

function Notify([string]$text, [string]$icon = 'Info') {
  $tray.BalloonTipTitle = $cfg.monitor
  $tray.BalloonTipText = $text
  $tray.BalloonTipIcon = $icon
  $tray.ShowBalloonTip(1500)
}
function Switch-To([string]$name) {
  try {
    $n = Set-MonitorInput -Source $name
    if ($n -gt 0) { Notify "Monitor -> $name" } else { Notify 'Nenhum monitor aceitou o comando' 'Warning' }
  } catch { Notify $_.Exception.Message 'Error'; Write-DdcLog "erro: $($_.Exception.Message)" }
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
$tray.Text = "$($cfg.monitor) - entrada"
$tray.Visible = $true

$menu = New-Object Windows.Forms.ContextMenuStrip
$menu.Font = New-Object Drawing.Font('Segoe UI', 10)
$title = $menu.Items.Add($cfg.monitor); $title.Enabled = $false
$menu.Items.Add('-') | Out-Null

# um item por entrada definida em config.inputs (ordem do arquivo), com a tecla de atalho no texto
$script:HotIds = @{}
foreach ($name in $cfg.inputs.Keys) {
  $label = "Mudar para $name"
  if ($cfg.hotkeys -and $cfg.hotkeys.Contains($name)) { $label += "`t$($cfg.hotkeys[$name])" }
  $item = $menu.Items.Add($label)
  $item.Tag = $name
  $item.Add_Click({ Switch-To $this.Tag })
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
$menu.Items.Add('-') | Out-Null
$miExit = $menu.Items.Add('Sair')
$miExit.Add_Click({ $tray.Visible = $false; $tray.Dispose(); if ($script:hk) { $script:hk.Dispose() }; [Windows.Forms.Application]::Exit() })
$tray.ContextMenuStrip = $menu

# clique esquerdo abre o menu; duplo clique manda para config.doubleClick
$tray.Add_MouseClick({ if ($_.Button -eq 'Left') { [Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [Reflection.BindingFlags]'NonPublic,Instance').Invoke($tray, $null) } })
$tray.Add_DoubleClick({ if ($cfg.doubleClick) { Switch-To $cfg.doubleClick } })

# ---------------------------------------------------------------- atalhos globais
$script:hk = New-Object DdcCi.HotKeyWindow
$script:hk.Callback = [Action[int]]{ param($id) if ($script:HotIds.ContainsKey($id)) { Switch-To $script:HotIds[$id] } }
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

# ---------------------------------------------------------------- seguir o KVM
# O KVM UGREEN so tem botao fisico. Ao apertar, o teclado (sentinela) some deste PC e o Windows manda
# WM_DEVICECHANGE. Apos um pequeno atraso (varias mensagens chegam juntas), conferimos se a sentinela
# ainda esta presente e mandamos o monitor para a entrada correspondente.
$script:KvmOn = [bool]($cfg.kvm -and $cfg.kvm.enabled)
$script:KvmPresent = $null
if ($cfg.kvm -and $cfg.kvm.sentinel) {
  $script:KvmPresent = Test-DevicePresent $cfg.kvm.sentinel
  Write-DdcLog ("KVM: sentinela {0} {1}; seguir={2}" -f $cfg.kvm.sentinel, $(if ($script:KvmPresent) { 'presente' } else { 'ausente' }), $script:KvmOn)
  $kvmTimer = New-Object Windows.Forms.Timer
  $kvmTimer.Interval = [int]$(if ($cfg.kvm.delayMs) { $cfg.kvm.delayMs } else { 1500 })
  $kvmTimer.Add_Tick({
    $kvmTimer.Stop()
    $now = Test-DevicePresent $cfg.kvm.sentinel
    if ($now -eq $script:KvmPresent) { return }
    $script:KvmPresent = $now
    if (-not $script:KvmOn) { return }
    if ($now) { Write-DdcLog 'KVM: teclado voltou'; Switch-To $cfg.kvm.onArrive }
    else      { Write-DdcLog 'KVM: teclado saiu';   Switch-To $cfg.kvm.onLeave }
  })
  $script:hk.DeviceChanged = [Action]{ $kvmTimer.Stop(); $kvmTimer.Start() }
}

Write-DdcLog 'tray iniciado'
[Windows.Forms.Application]::Run()
$mutex.ReleaseMutex()
