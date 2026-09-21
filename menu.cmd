@echo off
setlocal
title Enviar valor ao VCP 0x60 (entrada do monitor)
:loop
echo.
echo  Valores deste Samsung LC34G55T (config.json):  06=HDMI   09=DisplayPort
echo  Padrao MCCS (nao funciona neste modelo):        0F=DP  11=HDMI1  12=HDMI2
echo  Digite o valor em hex (ex: 09), ou "s" para sair.
set /p V=" > "
if /i "%V%"=="s" goto :eof
if "%V%"=="" goto loop
set /a DEC=0x%V% 2>nul || (echo valor invalido & goto loop)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-MonitorInput.ps1" -Raw %DEC%
goto loop
