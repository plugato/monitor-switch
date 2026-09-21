<#
.SYNOPSIS
  Troca a entrada do monitor via DDC/CI (linha de comando).
.EXAMPLE
  .\Set-MonitorInput.ps1 -Source DP        # nomes definidos em config.json (HDMI, DP)
  .\Set-MonitorInput.ps1 -Raw 9            # valor numerico direto no VCP 0x60
.NOTES
  Nao use $Input como nome de parametro: e variavel reservada do PowerShell (bug historico deste projeto).
#>
param(
  [string]$Source,
  [int]$Raw = -1
)
Import-Module (Join-Path $PSScriptRoot 'DdcCi.psm1') -Force
if (-not $Source -and $Raw -lt 0) {
  $cfg = Get-MonitorConfig
  Write-Host "Uso: Set-MonitorInput.ps1 -Source <$($cfg.inputs.Keys -join '|')>  ou  -Raw <valor>"
  exit 1
}
$n = Set-MonitorInput -Source $Source -Raw $Raw
$rotulo = if ($Source) { $Source } else { ('0x{0:X2}' -f $Raw) }
Write-Host ("Monitor -> {0}  (comando aceito por {1} monitor(es))" -f $rotulo, $n)
if ($n -eq 0) { exit 2 }
