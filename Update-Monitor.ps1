<#
.SYNOPSIS
  Atualiza o monitor-switch pelas Releases do GitHub (pacote monitor-switch-windows-<tag>.zip).
.EXAMPLE
  .\Update-Monitor.ps1            # verifica e, se houver versao nova, instala
  .\Update-Monitor.ps1 -Check     # so compara a versao instalada com a ultima release
.NOTES
  A bandeja chama com -Tag <tag> -WaitPid <pid da bandeja> -Restart: espera a bandeja fechar, instala e
  abre a bandeja de novo, que mostra o resultado num balao.
  Preserva config.json e logs\. O .zip e conferido com o SHA256SUMS.txt da release antes de copiar.
  Numa copia git (pasta de desenvolvimento) usa 'git pull --ff-only' em vez do pacote.
#>
param(
  [switch]$Check,
  [string]$Tag,
  [int]$WaitPid = 0,
  [switch]$Restart
)
Import-Module (Join-Path $PSScriptRoot 'DdcCi.psm1') -Force
$Root = $PSScriptRoot
$Marker = Join-Path $env:TEMP 'monitor-switch-updated.txt'   # lido pela bandeja ao iniciar
function Say([string]$msg) { Write-Host $msg; Write-DdcLog "update: $msg" }

$cur = Get-InstalledVersion
if (-not $Tag) {
  try { $Tag = Get-LatestRelease } catch { Say "nao consegui consultar as releases de $(Get-UpdateSetting repo): $($_.Exception.Message)"; exit 1 }
}
if (-not (Test-NewerVersion $cur $Tag)) { Say "versao $cur ja e a mais recente ($Tag)"; if ($Restart) { Start-Process wscript.exe "`"$(Join-Path $Root 'MonitorTray.vbs')`"" }; exit 0 }
if ($Check) { Say "nova versao disponivel: $Tag (instalada: $cur)"; exit 0 }

if ($WaitPid) { Wait-Process -Id $WaitPid -Timeout 20 -ErrorAction SilentlyContinue }
$ok = $false; $tmp = $null
try {
  if (Test-GitCheckout) {
    git -C $Root pull --ff-only -q
    if ($LASTEXITCODE) { throw 'git pull --ff-only falhou (alteracoes locais ou branch divergente); atualize na mao' }
  } else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path $env:TEMP ("monitor-switch-update-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $pkg = "monitor-switch-windows-$Tag.zip"
    $base = "https://github.com/$(Get-UpdateSetting repo)/releases/download/$Tag"
    $zip = Join-Path $tmp $pkg; $sums = Join-Path $tmp 'SHA256SUMS.txt'
    Invoke-WebRequest "$base/$pkg" -OutFile $zip -UseBasicParsing -TimeoutSec 120
    Invoke-WebRequest "$base/SHA256SUMS.txt" -OutFile $sums -UseBasicParsing -TimeoutSec 30
    $line = Get-Content $sums | Where-Object { ($_ -split '\s+')[-1].TrimStart('*') -eq $pkg } | Select-Object -First 1
    if (-not $line) { throw "$pkg nao esta no SHA256SUMS.txt da release" }
    $expected = ($line -split '\s+')[0].ToLower()
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) { throw "SHA-256 de $pkg nao confere; nada foi alterado" }
    Expand-Archive $zip -DestinationPath $tmp -Force
    $src = Join-Path $tmp "monitor-switch-windows-$Tag"
    if (-not (Test-Path (Join-Path $src 'DdcCi.psm1'))) { throw "pacote $pkg com formato inesperado" }
    Remove-Item (Join-Path $src 'config.json') -ErrorAction SilentlyContinue   # o config.json do usuario fica como esta
    Copy-Item (Join-Path $src '*') $Root -Recurse -Force
  }
  $ok = $true
  Say "monitor-switch atualizado: $cur -> $(Get-InstalledVersion)"
  Set-Content $Marker "Atualizado: $cur -> $(Get-InstalledVersion)" -Encoding UTF8
} catch {
  Say "falha na atualizacao: $($_.Exception.Message)"
  Set-Content $Marker "Falha ao atualizar para ${Tag}: $($_.Exception.Message)" -Encoding UTF8
} finally {
  if ($tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($Restart) { Start-Process wscript.exe "`"$(Join-Path $Root 'MonitorTray.vbs')`"" }
if (-not $ok) { exit 1 }
