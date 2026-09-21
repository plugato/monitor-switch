# Icone de bandeja para trocar a entrada do Samsung Odyssey G5 (LC34G55T) via DDC/CI
# Iniciar: MonitorTray.vbs (sem janela)   |   HDMI = 0x06   DisplayPort = 0x09
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public class DDCT {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct PM { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string desc; }
  public delegate bool Proc(IntPtr a, IntPtr b, IntPtr c, IntPtr d);
  [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr a, IntPtr b, Proc p, IntPtr d);
  [DllImport("dxva2.dll")] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
  [DllImport("dxva2.dll")] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PM[] a);
  [DllImport("dxva2.dll")] public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte c, out uint t, out uint cur, out uint max);
  [DllImport("dxva2.dll")] public static extern bool SetVCPFeature(IntPtr h, byte c, uint v);
  [DllImport("dxva2.dll")] public static extern bool DestroyPhysicalMonitors(uint n, PM[] a);
}
"@

# evita duas instancias
$mutex = New-Object Threading.Mutex($false, 'Global\OdysseyG5TrayMutex')
if (-not $mutex.WaitOne(0)) { exit }

$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Codes = @{ HDMI = 0x06; DP = 0x09 }

function Send-Input([string]$name) {
  # Enumera os monitores a cada chamada: manda 0x60 para todo monitor que responder DDC/CI
  # (a tela do notebook ignora). Nao exige leitura previa, para funcionar mesmo com o monitor em outra entrada.
  $script:mons = @()
  [DDCT]::EnumDisplayMonitors([IntPtr]::Zero,[IntPtr]::Zero,[DDCT+Proc]{ param($h,$b,$c,$d) $script:mons += $h; $true },[IntPtr]::Zero) | Out-Null
  $sent = 0
  foreach ($hm in $script:mons) {
    $n = 0; [DDCT]::GetNumberOfPhysicalMonitorsFromHMONITOR($hm,[ref]$n) | Out-Null
    $arr = New-Object 'DDCT+PM[]' $n
    [DDCT]::GetPhysicalMonitorsFromHMONITOR($hm,$n,$arr) | Out-Null
    foreach ($pm in $arr) { if ([DDCT]::SetVCPFeature($pm.h,0x60,[uint32]$Codes[$name])) { $sent++ } }
    [DDCT]::DestroyPhysicalMonitors($n,$arr) | Out-Null
  }
  $tray.BalloonTipTitle = 'Odyssey G5'
  $tray.BalloonTipText = if ($sent -gt 0) { "Monitor -> $name" } else { 'Nenhum monitor respondeu' }
  $tray.ShowBalloonTip(1500)
}

# icone desenhado (monitor) - nao depende de arquivo externo
function New-TrayIcon {
  $bmp = New-Object Drawing.Bitmap 16,16
  $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
  $g.Clear([Drawing.Color]::Transparent)
  $g.FillRectangle([Drawing.Brushes]::White, 1, 2, 14, 9)
  $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(30,144,255))), 2, 3, 12, 7)
  $g.FillRectangle([Drawing.Brushes]::White, 6, 11, 4, 2)
  $g.FillRectangle([Drawing.Brushes]::White, 4, 13, 8, 1)
  $g.Dispose()
  [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Odyssey G5 Tray.lnk'
function Set-Startup([bool]$on) {
  if ($on) {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($StartupLnk)
    $lnk.TargetPath = 'wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $Dir 'MonitorTray.vbs') + '"'
    $lnk.WorkingDirectory = $Dir
    $lnk.Description = 'Troca de entrada do monitor Odyssey G5'
    $lnk.Save()
  } elseif (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force }
}

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon
$tray.Text = 'Odyssey G5 - entrada do monitor'
$tray.Visible = $true

$menu = New-Object Windows.Forms.ContextMenuStrip
$menu.Font = New-Object Drawing.Font('Segoe UI', 10)

$title = $menu.Items.Add('Samsung Odyssey G5'); $title.Enabled = $false
$menu.Items.Add('-') | Out-Null
$miHdmi = $menu.Items.Add('Mudar para HDMI');        $miHdmi.Add_Click({ Send-Input 'HDMI' })
$miDp   = $menu.Items.Add('Mudar para DisplayPort'); $miDp.Add_Click({ Send-Input 'DP' })
$menu.Items.Add('-') | Out-Null
$miFull = $menu.Items.Add('Abrir controle completo...')
$miFull.Add_Click({ Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$(Join-Path $Dir 'MonitorControl.ps1')`"" })
$miStart = $menu.Items.Add('Iniciar com o Windows'); $miStart.CheckOnClick = $true
$miStart.Checked = Test-Path $StartupLnk
$miStart.Add_Click({ Set-Startup $this.Checked })
$menu.Items.Add('-') | Out-Null
$miExit = $menu.Items.Add('Sair'); $miExit.Add_Click({ $tray.Visible = $false; $tray.Dispose(); [Windows.Forms.Application]::Exit() })
$tray.ContextMenuStrip = $menu

# clique esquerdo abre o mesmo menu; duplo clique manda para DisplayPort (a "outra" entrada vista deste PC)
$tray.Add_MouseClick({ if ($_.Button -eq 'Left') { $m = [Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu',[Reflection.BindingFlags]'NonPublic,Instance'); $m.Invoke($tray,$null) } })
$tray.Add_DoubleClick({ Send-Input 'DP' })

[Windows.Forms.Application]::Run()
$mutex.ReleaseMutex()
