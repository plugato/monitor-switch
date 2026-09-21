@echo off
setlocal
title Trocar entrada do monitor (DDC/CI 0x60)
:loop
echo.
echo  Valores padrao MCCS:  0F=DP1  10=DP2  11=HDMI1  12=HDMI2  0x01..0x12 (VGA/DVI/etc)
echo  Neste Samsung LC34G55T:  06=HDMI   09=DisplayPort
echo  Digite o valor em hex (ex: 0A), ou "s" para sair.
set /p V=" > "
if /i "%V%"=="s" goto :eof
if "%V%"=="" goto loop
set /a DEC=0x%V% 2>nul || (echo valor invalido & goto loop)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-MonitorInput.ps1" -Raw %DEC%
goto loop
