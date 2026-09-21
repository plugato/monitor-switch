# DdcCi.psm1 - modulo compartilhado de acesso DDC/CI (dxva2.dll) para o projeto monitor-input
# Importado por Set-MonitorInput.ps1, MonitorControl.ps1 e MonitorTray.ps1.

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not ('DdcCi.Native' -as [type])) {
Add-Type -ReferencedAssemblies System.Windows.Forms @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace DdcCi {
  public class Native {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR {
      public IntPtr hPhysicalMonitor;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szPhysicalMonitorDescription;
    }
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);
    [DllImport("dxva2.dll")]  public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint count);
    [DllImport("dxva2.dll")]  public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint count, [Out] PHYSICAL_MONITOR[] arr);
    [DllImport("dxva2.dll")]  public static extern bool DestroyPhysicalMonitors(uint count, PHYSICAL_MONITOR[] arr);
    [DllImport("dxva2.dll")]  public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out uint type, out uint current, out uint maximum);
    [DllImport("dxva2.dll")]  public static extern bool SetVCPFeature(IntPtr h, byte code, uint value);
    [DllImport("dxva2.dll")]  public static extern bool GetCapabilitiesStringLength(IntPtr h, out uint length);
    [DllImport("dxva2.dll")]  public static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr h, StringBuilder sb, uint length);
  }

  // Janela invisivel que recebe WM_HOTKEY (atalhos globais) e WM_DEVICECHANGE (USB conectado/removido).
  public class HotKeyWindow : NativeWindow, IDisposable {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    const int WM_HOTKEY = 0x0312;
    const int WM_DEVICECHANGE = 0x0219;
    const int DBT_DEVNODES_CHANGED = 0x0007;
    public Action<int> Callback;        // id do atalho pressionado
    public Action DeviceChanged;        // qualquer mudanca na arvore de dispositivos
    int next = 1;
    public HotKeyWindow() { CreateHandle(new CreateParams()); }
    public int Register(uint modifiers, uint vk) {
      int id = next++;
      if (!RegisterHotKey(Handle, id, modifiers | 0x4000 /*MOD_NOREPEAT*/, vk)) return -1;
      return id;
    }
    protected override void WndProc(ref Message m) {
      if (m.Msg == WM_HOTKEY && Callback != null) Callback((int)m.WParam);
      if (m.Msg == WM_DEVICECHANGE && (int)m.WParam == DBT_DEVNODES_CHANGED && DeviceChanged != null) DeviceChanged();
      base.WndProc(ref m);
    }
    public void Dispose() { for (int i = 1; i < next; i++) UnregisterHotKey(Handle, i); DestroyHandle(); }
  }

  // Lista rapida (poucos ms) dos InstanceIds USB presentes, via cfgmgr32. Get-PnpDevice leva ~2 s.
  public class CfgMgr {
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Get_Device_ID_List_SizeW(out uint len, string filter, uint flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Get_Device_ID_ListW(string filter, char[] buffer, uint len, uint flags);
    const uint FILTER_ENUMERATOR = 0x1, FILTER_PRESENT = 0x100;
    public static string[] PresentIds(string enumerator) {
      uint len;
      if (CM_Get_Device_ID_List_SizeW(out len, enumerator, FILTER_ENUMERATOR | FILTER_PRESENT) != 0 || len == 0) return new string[0];
      var buf = new char[len];
      if (CM_Get_Device_ID_ListW(enumerator, buf, len, FILTER_ENUMERATOR | FILTER_PRESENT) != 0) return new string[0];
      return new string(buf).Split(new[] { '\0' }, StringSplitOptions.RemoveEmptyEntries);
    }
  }
}
"@
}

# ---------------------------------------------------------------- configuracao
function Get-MonitorConfig {
  <# Le config.json ao lado do modulo. Valores padrao cobrem o Samsung Odyssey G5 LC34G55T. #>
  $defaults = [ordered]@{
    monitor     = 'Samsung Odyssey G5 (LC34G55T)'
    inputs      = [ordered]@{ HDMI = 6; DP = 9 }
    hotkeys     = [ordered]@{ HDMI = 'Ctrl+Alt+1'; DP = 'Ctrl+Alt+2' }
    doubleClick = 'DP'
    logFile     = 'logs\monitor.log'
    # Seguir o KVM: quando o dispositivo-sentinela (teclado atras do KVM) some deste PC, manda o monitor
    # para onLeave; quando volta, manda para onArrive. Prefixo do InstanceId (Get-PnpDevice).
    kvm         = [ordered]@{ enabled = $false; sentinel = 'USB\VID_046D&PID_C33A'; onLeave = 'DP'; onArrive = 'HDMI'; delayMs = 400 }
  }
  $path = Join-Path $script:Root 'config.json'
  if (Test-Path $path) {
    try {
      $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($p in $json.PSObject.Properties) {
        if ($p.Value -is [pscustomobject]) {
          $h = [ordered]@{}; foreach ($q in $p.Value.PSObject.Properties) { $h[$q.Name] = $q.Value }
          $defaults[$p.Name] = $h
        } else { $defaults[$p.Name] = $p.Value }
      }
    } catch { Write-DdcLog "config.json invalido, usando padroes: $($_.Exception.Message)" }
  }
  [pscustomobject]$defaults
}

# ---------------------------------------------------------------- log
function Write-DdcLog([string]$Message) {
  try {
    $cfg = Get-MonitorConfig
    $file = Join-Path $script:Root $cfg.logFile
    $dir = Split-Path -Parent $file
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ((Test-Path $file) -and (Get-Item $file).Length -gt 1MB) { Move-Item $file "$file.old" -Force }
    Add-Content -Path $file -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message) -Encoding UTF8
  } catch { }
}

# ---------------------------------------------------------------- monitores
function Get-DdcMonitors {
  <# Lista os monitores fisicos. Responds=True para os que respondem a leitura DDC/CI (brilho, 0x10).
     -NoProbe pula essa leitura (Responds=$null): usado no caminho de escrita, onde cada tentativa custa ~120 ms. #>
  param([switch]$NoProbe)
  $script:__hmons = @()
  [DdcCi.Native]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero,
    [DdcCi.Native+MonitorEnumProc]{ param($h, $dc, $r, $d) $script:__hmons += $h; $true }, [IntPtr]::Zero) | Out-Null
  $list = @()
  foreach ($hm in $script:__hmons) {
    $n = 0
    if (-not [DdcCi.Native]::GetNumberOfPhysicalMonitorsFromHMONITOR($hm, [ref]$n) -or $n -eq 0) { continue }
    $arr = New-Object 'DdcCi.Native+PHYSICAL_MONITOR[]' $n
    if (-not [DdcCi.Native]::GetPhysicalMonitorsFromHMONITOR($hm, $n, $arr)) { continue }
    foreach ($pm in $arr) {
      # a leitura pode falhar de forma transitoria logo apos uma escrita: tenta ate 3 vezes
      $ok = $null
      if ($NoProbe) { $list += [pscustomobject]@{ Handle = $pm.hPhysicalMonitor; Description = $pm.szPhysicalMonitorDescription; Responds = $null }; continue }
      $ok = $false
      for ($try = 0; $try -lt 3 -and -not $ok; $try++) {
        $t = 0; $c = 0; $m = 0
        $ok = [DdcCi.Native]::GetVCPFeatureAndVCPFeatureReply($pm.hPhysicalMonitor, 0x10, [ref]$t, [ref]$c, [ref]$m)
        if (-not $ok) { Start-Sleep -Milliseconds 120 }
      }
      $list += [pscustomobject]@{ Handle = $pm.hPhysicalMonitor; Description = $pm.szPhysicalMonitorDescription; Responds = $ok }
    }
  }
  $list
}

function Get-DdcMonitor {
  <# Primeiro monitor que responde DDC/CI, ou $null. #>
  Get-DdcMonitors | Where-Object Responds | Select-Object -First 1
}

# ---------------------------------------------------------------- VCP
function Read-Vcp([IntPtr]$Handle, [int]$Code) {
  $t = 0; $c = 0; $m = 0
  $ok = [DdcCi.Native]::GetVCPFeatureAndVCPFeatureReply($Handle, [byte]$Code, [ref]$t, [ref]$c, [ref]$m)
  [pscustomobject]@{ Ok = $ok; Current = $c; Maximum = $m; Type = $t }
}

function Write-Vcp([IntPtr]$Handle, [int]$Code, [int]$Value) {
  $ok = [DdcCi.Native]::SetVCPFeature($Handle, [byte]$Code, [uint32]$Value)
  Write-DdcLog ("set 0x{0:X2} <- {1} (0x{1:X2}) {2}" -f $Code, $Value, $(if ($ok) { 'ok' } else { 'FALHOU' }))
  $ok
}

function Get-DdcCapabilities([IntPtr]$Handle) {
  $len = 0
  if (-not [DdcCi.Native]::GetCapabilitiesStringLength($Handle, [ref]$len) -or $len -eq 0) { return $null }
  $sb = New-Object System.Text.StringBuilder ([int]$len)
  if ([DdcCi.Native]::CapabilitiesRequestAndCapabilitiesReply($Handle, $sb, $len)) { $sb.ToString() } else { $null }
}

function Set-MonitorInput {
  <#
    Troca a entrada do monitor (VCP 0x60).
    -Source: nome definido em config.json (HDMI, DP).  -Raw: valor numerico direto.
    Envia para TODOS os monitores fisicos, sem exigir leitura previa: assim funciona mesmo quando o
    Samsung esta exibindo outra entrada (a tela do notebook simplesmente ignora o comando).
    Retorna quantos monitores aceitaram a escrita.
  #>
  param([string]$Source, [int]$Raw = -1)
  $cfg = Get-MonitorConfig
  if ($Raw -lt 0) {
    if (-not $Source -or -not $cfg.inputs.Contains($Source)) { throw "Entrada desconhecida '$Source'. Opcoes: $($cfg.inputs.Keys -join ', ')" }
    $Raw = [int]$cfg.inputs[$Source]
  }
  $sent = 0
  foreach ($mon in (Get-DdcMonitors -NoProbe)) {
    if ([DdcCi.Native]::SetVCPFeature($mon.Handle, 0x60, [uint32]$Raw)) { $sent++ }
  }
  Write-DdcLog ("entrada -> {0} (0x{1:X2}) enviado a {2} monitor(es)" -f $(if ($Source) { $Source } else { 'raw' }), $Raw, $sent)
  $sent
}

# ---------------------------------------------------------------- dispositivos USB (KVM)
function Test-DevicePresent([string]$InstanceIdPrefix) {
  <# True se existe um dispositivo presente cujo InstanceId comece com o prefixo (ex.: 'USB\VID_046D&PID_C33A').
     Usa cfgmgr32 (poucos ms). O enumerador e a parte antes da primeira barra (USB, HID, PCI...). #>
  $p = $InstanceIdPrefix.TrimEnd('*')
  $enum = $p.Split('\')[0]
  foreach ($id in [DdcCi.CfgMgr]::PresentIds($enum)) { if ($id.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
  $false
}

# ---------------------------------------------------------------- hotkeys
function ConvertTo-HotKey([string]$Text) {
  <# 'Ctrl+Alt+1' -> @{ Modifiers=6; Key=0x31 }.  Modificadores: Alt=1 Ctrl=2 Shift=4 Win=8 #>
  $mods = 0; $key = 0
  foreach ($tok in ($Text -split '\+' | ForEach-Object { $_.Trim() })) {
    switch -Regex ($tok) {
      '^(ctrl|control)$' { $mods = $mods -bor 2 }
      '^alt$'            { $mods = $mods -bor 1 }
      '^shift$'          { $mods = $mods -bor 4 }
      '^(win|windows)$'  { $mods = $mods -bor 8 }
      '^[0-9]$'          { $key = [int][System.Windows.Forms.Keys]"D$tok" }
      default            { $key = [int][System.Windows.Forms.Keys]$tok }
    }
  }
  if ($key -eq 0) { throw "Tecla invalida em '$Text'" }
  @{ Modifiers = [uint32]$mods; Key = [uint32]$key }
}

Export-ModuleMember -Function Get-MonitorConfig, Write-DdcLog, Get-DdcMonitors, Get-DdcMonitor, Read-Vcp, Write-Vcp, Get-DdcCapabilities, Set-MonitorInput, ConvertTo-HotKey, Test-DevicePresent
