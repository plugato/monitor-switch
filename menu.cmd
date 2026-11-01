@echo off
setlocal
title Enviar valor ao VCP 0x60 (entrada do monitor)
rem Nome (config.json ou EDID, via Get-MonitorName) e valores de "inputs" lidos uma vez: importar o modulo leva ~1 s.
set "HDR=config.json"
for /f "usebackq delims=" %%L in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '%~dp0DdcCi.psm1'; $c = Get-MonitorConfig; '{0} (config.json):  {1}' -f (Get-MonitorName), (($c.inputs.Keys | ForEach-Object { '{0:X2}={1}' -f [int]$c.inputs[$_], $_ }) -join '   ')"`) do set "HDR=%%L"
:loop
echo.
echo  Valores deste %HDR%
echo  Padrao MCCS (a Samsung usa valores proprios):  0F=DP  11=HDMI1  12=HDMI2
echo  Digite o valor em hex (ex: 09), ou "s" para sair.
set /p V=" > "
if /i "%V%"=="s" goto :eof
if "%V%"=="" goto loop
set /a DEC=0x%V% 2>nul || (echo valor invalido & goto loop)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-MonitorInput.ps1" -Raw %DEC%
goto loop
