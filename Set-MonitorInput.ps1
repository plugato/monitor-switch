param([ValidateSet('DP','HDMI','HDMI1','HDMI2')][string]$Source, [int]$Raw = -1)
$codes = @{ DP = 0x09; HDMI = 0x06; HDMI1 = 0x06; HDMI2 = 0x06 }
Add-Type @"
using System; using System.Runtime.InteropServices;
public class DDC {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct PM { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string desc; }
  public delegate bool Proc(IntPtr a, IntPtr b, IntPtr c, IntPtr d);
  [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr a, IntPtr b, Proc p, IntPtr d);
  [DllImport("dxva2.dll")] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
  [DllImport("dxva2.dll")] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PM[] a);
  [DllImport("dxva2.dll")] public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte c, IntPtr t, out uint cur, out uint max);
  [DllImport("dxva2.dll")] public static extern bool SetVCPFeature(IntPtr h, byte c, uint v);
  [DllImport("dxva2.dll")] public static extern bool DestroyPhysicalMonitors(uint n, PM[] a);
}
"@
$mons = @()
[DDC]::EnumDisplayMonitors([IntPtr]::Zero,[IntPtr]::Zero,[DDC+Proc]{ param($h,$b,$c,$d) $script:mons += $h; $true },[IntPtr]::Zero) | Out-Null
foreach ($hm in $mons) {
  $n=0; [DDC]::GetNumberOfPhysicalMonitorsFromHMONITOR($hm,[ref]$n) | Out-Null
  $arr = New-Object 'DDC+PM[]' $n
  [DDC]::GetPhysicalMonitorsFromHMONITOR($hm,$n,$arr) | Out-Null
  foreach ($pm in $arr) {
    $cur=0;$max=0
    # so mexe em monitor que responde ao VCP 0x60 (o Samsung; a tela do notebook nao responde)
    $lido = [DDC]::GetVCPFeatureAndVCPFeatureReply($pm.h,0x60,[IntPtr]::Zero,[ref]$cur,[ref]$max)
    if ($lido -or $pm.desc -notmatch "^$") {
      $val = if ($Raw -ge 0) { $Raw } else { $codes[$Source] }; $ok = [DDC]::SetVCPFeature($pm.h,0x60,$val)
      "Monitor externo -> $Source (0x{0:X2}) ok=$ok" -f $val
    }
  }
  [DDC]::DestroyPhysicalMonitors($n,$arr) | Out-Null
}
