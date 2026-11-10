<#
  MonitorBeacon.ps1 - avisa o outro PC (rede local) que este PC esta ligado, antes de alguem fazer login.
  Instalado pela bandeja (menu "Avisar o outro PC ja na tela de login") como tarefa agendada do SYSTEM, ao
  iniciar o Windows. Envia so 'hello' a cada 5 s (entrada deste PC, teclado-sentinela aqui, monitor conectado);
  com o teclado aqui, o outro PC, que esta na tela, manda o monitor para ca e a tela de login aparece.
  Fica quieto enquanto a bandeja (MonitorTray.ps1) esta rodando: ela faz o mesmo e mais.
  Nao fala DDC/CI (a sessao do SYSTEM nao tem acesso ao monitor).
#>
Import-Module (Join-Path $PSScriptRoot 'DdcCi.psm1') -Force

function Test-TrayRunning {
  $m = $null
  if ([Threading.Mutex]::TryOpenExisting('Global\OdysseyG5TrayMutex', [ref]$m)) { $m.Dispose(); return $true }
  $false
}

$udp = New-Object Net.Sockets.UdpClient
$udp.EnableBroadcast = $true
$monAt = [datetime]::MinValue; $mon = $true
Write-DdcLog 'aviso na tela de login: iniciado'
while ($true) {
  if (-not (Test-TrayRunning)) {
    $cfg = Get-MonitorConfig
    if ("$(Get-PeerSetting enabled)" -match '^(true|1)$' -and $cfg.kvm -and $cfg.kvm.sentinel) {
      if (((Get-Date) - $monAt).TotalSeconds -ge 30) { $mon = Test-MonitorAttached; $monAt = Get-Date }
      $kbd = if (Test-DevicePresent $cfg.kvm.sentinel) { 1 } else { 0 }
      $bytes = New-PeerMessage hello @{ in = [string]$cfg.kvm.onArrive; kbd = $kbd; mon = $(if ($mon) { 1 } else { 0 }) }
      $port = [int](Get-PeerSetting port)
      $targets = @('255.255.255.255'); $h = [string](Get-PeerSetting host); if ($h) { $targets += $h }
      foreach ($t in $targets) { try { [void]$udp.Send($bytes, $bytes.Length, $t, $port) } catch { } }
    }
  }
  Start-Sleep -Seconds 5
}
