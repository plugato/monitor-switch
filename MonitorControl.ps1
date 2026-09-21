# Controle do monitor Samsung Odyssey G5 (LC34G55T) via DDC/CI
# Uso: MonitorControl.cmd (ou powershell -ExecutionPolicy Bypass -File MonitorControl.ps1)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public class DDCX {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct PM { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string desc; }
  public delegate bool Proc(IntPtr a, IntPtr b, IntPtr c, IntPtr d);
  [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr a, IntPtr b, Proc p, IntPtr d);
  [DllImport("dxva2.dll")] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
  [DllImport("dxva2.dll")] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PM[] a);
  [DllImport("dxva2.dll")] public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte c, out uint t, out uint cur, out uint max);
  [DllImport("dxva2.dll")] public static extern bool SetVCPFeature(IntPtr h, byte c, uint v);
  [DllImport("dxva2.dll")] public static extern bool GetCapabilitiesStringLength(IntPtr h, out uint len);
  [DllImport("dxva2.dll")] public static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr h, StringBuilder sb, uint len);
}
"@

# ---------- DDC/CI ----------
$script:Mon = [IntPtr]::Zero
function Find-Monitor {
  $script:mons = @()
  [DDCX]::EnumDisplayMonitors([IntPtr]::Zero,[IntPtr]::Zero,[DDCX+Proc]{ param($h,$b,$c,$d) $script:mons += $h; $true },[IntPtr]::Zero) | Out-Null
  foreach ($hm in $script:mons) {
    $n = 0; [DDCX]::GetNumberOfPhysicalMonitorsFromHMONITOR($hm,[ref]$n) | Out-Null
    $arr = New-Object 'DDCX+PM[]' $n
    [DDCX]::GetPhysicalMonitorsFromHMONITOR($hm,$n,$arr) | Out-Null
    foreach ($pm in $arr) {
      $t=0;$c=0;$m=0
      if ([DDCX]::GetVCPFeatureAndVCPFeatureReply($pm.h,0x10,[ref]$t,[ref]$c,[ref]$m)) { $script:Mon = $pm.h; return $true }
    }
  }
  return $false
}
function Read-VCP([int]$code) {
  $t=0;$c=0;$m=0
  $ok = [DDCX]::GetVCPFeatureAndVCPFeatureReply($script:Mon,[byte]$code,[ref]$t,[ref]$c,[ref]$m)
  [pscustomobject]@{ ok=$ok; cur=$c; max=$m }
}
function Write-VCP([int]$code,[int]$val,[string]$desc) {
  $ok = [DDCX]::SetVCPFeature($script:Mon,[byte]$code,[uint32]$val)
  $st = 'ok'; if (-not $ok) { $st = 'FALHOU' }
  Log ("{0}  0x{1:X2} <- {2} (0x{2:X2})  {3}" -f $desc,$code,$val,$st)
  return $ok
}
function Log([string]$s) {
  $script:txtLog.AppendText(("[{0:HH:mm:ss}] {1}`r`n" -f (Get-Date),$s))
}

# ---------- GUI ----------
$form = New-Object Windows.Forms.Form
$form.Text = 'Odyssey G5 - Controle DDC/CI'
$form.Size = '640,760'; $form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
$form.Font = New-Object Drawing.Font('Segoe UI',9)

$tabs = New-Object Windows.Forms.TabControl
$tabs.Location = '10,10'; $tabs.Size = '605,530'
$form.Controls.Add($tabs)

$script:txtLog = New-Object Windows.Forms.TextBox
$txtLog.Multiline = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.ReadOnly = $true
$txtLog.Location = '10,580'; $txtLog.Size = '605,135'; $txtLog.Font = New-Object Drawing.Font('Consolas',8.5)
$form.Controls.Add($txtLog)

$btnRefresh = New-Object Windows.Forms.Button
$btnRefresh.Text = 'Atualizar valores do monitor'; $btnRefresh.Location = '10,548'; $btnRefresh.Size = '220,26'
$form.Controls.Add($btnRefresh)
$lblStatus = New-Object Windows.Forms.Label
$lblStatus.Location = '240,552'; $lblStatus.Size = '375,20'; $lblStatus.Text = ''
$form.Controls.Add($lblStatus)

function New-Tab($title) { $t = New-Object Windows.Forms.TabPage; $t.Text = $title; $t.Padding = '8,8,8,8'; $tabs.TabPages.Add($t); $t }
function Add-Label($parent,$text,$x,$y,$w=200,$bold=$false) {
  $l = New-Object Windows.Forms.Label; $l.Text=$text; $l.Location="$x,$y"; $l.Size="$w,20"
  if ($bold) { $l.Font = New-Object Drawing.Font('Segoe UI',9,[Drawing.FontStyle]::Bold) }
  $parent.Controls.Add($l); $l
}
function Add-Button($parent,$text,$x,$y,$w,$h,$onClick) {
  $b = New-Object Windows.Forms.Button; $b.Text=$text; $b.Location="$x,$y"; $b.Size="$w,$h"
  $b.Add_Click($onClick); $parent.Controls.Add($b); $b
}
$script:Sliders = @{}
$script:Pending = @{}
function Add-Slider($parent,$label,$code,$y,$max=100) {
  Add-Label $parent $label 10 ($y+2) 130 | Out-Null
  $tb = New-Object Windows.Forms.TrackBar
  $tb.Location = "140,$y"; $tb.Size = '360,40'; $tb.Minimum = 0; $tb.Maximum = $max; $tb.TickFrequency = [math]::Max(1,[int]($max/10))
  $val = New-Object Windows.Forms.NumericUpDown
  $val.Location = "510,$($y+2)"; $val.Size = '60,24'; $val.Minimum = 0; $val.Maximum = $max
  $tb.Tag = $code; $val.Tag = $code
  $tb.Add_Scroll({ $c=$this.Tag; $script:Sliders[$c].num.Value = $this.Value; $script:Pending[$c] = @{v=$this.Value; d=$script:Sliders[$c].label} })
  $val.Add_ValueChanged({ $c=$this.Tag; if ($script:Sliders[$c].tb.Value -ne $this.Value) { $script:Sliders[$c].tb.Value = [int]$this.Value; $script:Pending[$c] = @{v=[int]$this.Value; d=$script:Sliders[$c].label} } })
  $parent.Controls.Add($tb); $parent.Controls.Add($val)
  $script:Sliders[$code] = @{ tb=$tb; num=$val; label=$label }
}
$script:Combos = @{}
function Add-Combo($parent,$label,$code,$y,$items) {
  Add-Label $parent $label 10 ($y+3) 180 | Out-Null
  $keys = @($items.Keys | Sort-Object)
  $cb = New-Object Windows.Forms.ComboBox; $cb.Location = "200,$y"; $cb.Size = '300,24'; $cb.DropDownStyle = 'DropDownList'
  foreach ($k in $keys) { $cb.Items.Add(("{0,3}  (0x{0:X2})  {1}" -f $k,$items[$k])) | Out-Null }
  $b = Add-Button $parent 'Aplicar' 510 ($y-1) 60 26 {
    $c = $script:Combos[$this.Tag]; $i = $c.cb.SelectedIndex
    if ($i -ge 0) { Write-VCP $this.Tag $c.keys[$i] $c.label | Out-Null }
  }
  $b.Tag = $code
  $parent.Controls.Add($cb)
  $script:Combos[$code] = @{ cb=$cb; keys=$keys; label=$label }
}
function Confirm($msg) { [Windows.Forms.MessageBox]::Show($msg,'Confirmar',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning) -eq 'Yes' }

# ===== Aba 1: Entrada e imagem =====
$tab1 = New-Tab 'Entrada e imagem'
Add-Label $tab1 'Fonte de entrada (VCP 0x60 - valores proprietarios Samsung)' 10 10 500 $true | Out-Null
Add-Button $tab1 'HDMI  (0x06)' 10 35 180 40 { Write-VCP 0x60 0x06 'Entrada HDMI' | Out-Null } | Out-Null
Add-Button $tab1 'DisplayPort  (0x09)' 200 35 180 40 { Write-VCP 0x60 0x09 'Entrada DisplayPort' | Out-Null } | Out-Null
Add-Label $tab1 'Obs.: se a outra entrada estiver sem sinal, o monitor dorme e so volta pelo botao.' 10 80 560 | Out-Null

Add-Label $tab1 'Ajustes de imagem (arraste ou digite; aplica em ~200 ms)' 10 115 500 $true | Out-Null
Add-Slider $tab1 'Brilho (0x10)'         0x10 140
Add-Slider $tab1 'Contraste (0x12)'      0x12 190
Add-Slider $tab1 'Nitidez (0x87)'        0x87 240
Add-Slider $tab1 'Ganho R (0x16)' 0x16 290
Add-Slider $tab1 'Ganho G (0x18)'  0x18 340
Add-Slider $tab1 'Ganho B (0x1A)'  0x1A 390
Add-Label $tab1 'Os ganhos RGB so tem efeito quando o preset de cor esta em modo personalizado (aba Cor e modo).' 10 440 560 | Out-Null

# ===== Aba 2: Cor e modo =====
$tab2 = New-Tab 'Cor e modo'
Add-Label $tab2 'Listas seguem o padrao MCCS; a Samsung pode usar rotulos diferentes no menu. Teste e observe.' 10 10 570 | Out-Null
Add-Combo $tab2 'Preset de cor (0x14)' 0x14 40 @{ 1='sRGB'; 2='Nativo / Normal'; 3='4000K'; 4='5000K'; 5='6500K'; 6='7500K'; 8='9300K'; 11='Usuario 1 (custom)'; 12='Usuario 2 (custom)' }
Add-Combo $tab2 'Modo de imagem (0xDC)' 0xDC 80 @{ 0='Padrao'; 1='Produtividade'; 2='Misto'; 3='Filme'; 4='Usuario'; 5='Jogo' }
Add-Combo $tab2 'Idioma do menu OSD (0xCC)' 0xCC 120 @{ 1='Chines (trad.)'; 2='Ingles'; 3='Frances'; 4='Alemao'; 5='Italiano'; 6='Japones'; 7='Coreano'; 8='Portugues (Portugal)'; 9='Russo'; 10='Espanhol'; 11='Sueco'; 12='Turco'; 13='Chines (simpl.)'; 14='Portugues (Brasil)'; 15='Arabe'; 16='Bulgaro'; 17='Croata'; 18='Tcheco'; 19='Dinamarques'; 20='Holandes'; 21='Estoniano'; 22='Finlandes'; 23='Grego'; 24='Hebraico'; 25='Hungaro'; 26='Letao'; 27='Lituano'; 28='Noruegues'; 29='Polones'; 30='Romeno' }

Add-Label $tab2 'Codigos proprietarios Samsung encontrados na varredura (funcao desconhecida; mude e observe o menu)' 10 170 570 $true | Out-Null
Add-Combo $tab2 '0xE0 (atual 2, max 5)' 0xE0 195 @{ 0='0'; 1='1'; 2='2'; 3='3'; 4='4'; 5='5' }
Add-Combo $tab2 '0xE1 (atual 2, max 5)' 0xE1 230 @{ 0='0'; 1='1'; 2='2'; 3='3'; 4='4'; 5='5' }
Add-Combo $tab2 '0xE2 (atual 2, max 5)' 0xE2 265 @{ 0='0'; 1='1'; 2='2'; 3='3'; 4='4'; 5='5' }
Add-Combo $tab2 '0xE5 (liga/desliga)'   0xE5 300 @{ 0='Desligado (0)'; 1='Ligado (1)' }
Add-Combo $tab2 '0xE6 (liga/desliga)'   0xE6 335 @{ 0='Desligado (0)'; 1='Ligado (1)' }
Add-Combo $tab2 '0xF3 (atual 1, max 2)' 0xF3 370 @{ 0='0'; 1='1'; 2='2' }
Add-Combo $tab2 '0xF7 (atual 0, max 3)' 0xF7 405 @{ 0='0'; 1='1'; 2='2'; 3='3' }
Add-Label $tab2 'Candidatos tipicos em Odyssey: tempo de resposta, Black Equalizer, FreeSync, Eye Saver, Low Input Lag.' 10 445 570 | Out-Null

# ===== Aba 3: Sistema =====
$tab3 = New-Tab 'Sistema'
Add-Label $tab3 'Energia (VCP 0xD6)' 10 10 300 $true | Out-Null
Add-Button $tab3 'Ligar (1)' 10 35 140 34 { Write-VCP 0xD6 1 'Energia: ligar' | Out-Null } | Out-Null
Add-Button $tab3 'Standby (4)' 160 35 140 34 { if (Confirm 'Colocar o monitor em standby? Ele deve voltar sozinho ao receber sinal, ou pelo botao.') { Write-VCP 0xD6 4 'Energia: standby' | Out-Null } } | Out-Null
Add-Button $tab3 'Desligar (5)' 310 35 140 34 { if (Confirm 'Desligar o monitor? Pode ser necessario ligar pelo botao fisico.') { Write-VCP 0xD6 5 'Energia: desligar' | Out-Null } } | Out-Null

Add-Label $tab3 'Restaurar padroes' 10 95 300 $true | Out-Null
Add-Button $tab3 'Brilho e contraste de fabrica (0x05)' 10 120 260 30 { if (Confirm 'Restaurar brilho e contraste de fabrica?') { Write-VCP 0x05 1 'Restaurar brilho/contraste' | Out-Null; & $script:RefreshAll } } | Out-Null
Add-Button $tab3 'Cores de fabrica (0x08)' 280 120 200 30 { if (Confirm 'Restaurar cores de fabrica?') { Write-VCP 0x08 1 'Restaurar cores' | Out-Null; & $script:RefreshAll } } | Out-Null
Add-Button $tab3 'TUDO de fabrica (0x04)' 10 160 260 30 { if (Confirm 'Restaurar TODAS as configuracoes de fabrica do monitor? Isso apaga seus ajustes.') { Write-VCP 0x04 1 'Restaurar tudo' | Out-Null; & $script:RefreshAll } } | Out-Null
Add-Button $tab3 'Salvar ajustes atuais (0xB0=1)' 280 160 200 30 { Write-VCP 0xB0 1 'Salvar ajustes' | Out-Null } | Out-Null

Add-Label $tab3 'Informacoes (somente leitura)' 10 215 300 $true | Out-Null
$script:txtInfo = New-Object Windows.Forms.TextBox
$txtInfo.Multiline = $true; $txtInfo.ReadOnly = $true; $txtInfo.ScrollBars = 'Vertical'
$txtInfo.Location = '10,240'; $txtInfo.Size = '570,240'; $txtInfo.Font = New-Object Drawing.Font('Consolas',9)
$tab3.Controls.Add($txtInfo)

# ===== Aba 4: Avancado =====
$tab4 = New-Tab 'Avancado'
Add-Label $tab4 'Enviar qualquer codigo VCP (hex). Cuidado: valores desconhecidos podem ter efeitos inesperados.' 10 10 570 | Out-Null
Add-Label $tab4 'Codigo (hex):' 10 45 90 | Out-Null
$script:txtCode = New-Object Windows.Forms.TextBox; $txtCode.Location = '100,42'; $txtCode.Size = '60,24'; $txtCode.Text = '60'; $tab4.Controls.Add($txtCode)
Add-Label $tab4 'Valor (hex):' 180 45 80 | Out-Null
$script:txtVal = New-Object Windows.Forms.TextBox; $txtVal.Location = '260,42'; $txtVal.Size = '60,24'; $txtVal.Text = '09'; $tab4.Controls.Add($txtVal)
Add-Button $tab4 'Ler' 340 40 80 28 {
  try { $c=[Convert]::ToInt32($script:txtCode.Text,16); $r=Read-VCP $c
    Log ("Leitura 0x{0:X2}: ok={1} atual={2} (0x{2:X2}) max={3} (0x{3:X2})" -f $c,$r.ok,$r.cur,$r.max) } catch { Log 'Codigo invalido' }
} | Out-Null
Add-Button $tab4 'Enviar' 430 40 80 28 {
  try { $c=[Convert]::ToInt32($script:txtCode.Text,16); $v=[Convert]::ToInt32($script:txtVal.Text,16); Write-VCP $c $v 'Manual' | Out-Null } catch { Log 'Codigo ou valor invalido' }
} | Out-Null
Add-Button $tab4 'Varrer todos os codigos legiveis (0x00-0xFF)' 10 85 300 28 {
  Log 'Varrendo...'; $found=0
  for ($c=0; $c -le 0xFF; $c++) { $r=Read-VCP $c; if ($r.ok) { $found++; Log ("  0x{0:X2}  atual={1,4} (0x{1:X2})  max={2,4} (0x{2:X2})" -f $c,$r.cur,$r.max) } }
  Log "Varredura concluida: $found codigos respondem."
} | Out-Null
Add-Button $tab4 'Mostrar string de capabilities' 320 85 250 28 {
  $len=0
  if ([DDCX]::GetCapabilitiesStringLength($script:Mon,[ref]$len)) { $sb = New-Object Text.StringBuilder ([int]$len)
    if ([DDCX]::CapabilitiesRequestAndCapabilitiesReply($script:Mon,$sb,$len)) { Log ('CAPS: ' + $sb.ToString()) } else { Log 'Falha ao ler capabilities' } }
} | Out-Null
Add-Label $tab4 'Referencia rapida (MCCS):' 10 130 300 $true | Out-Null
$ref = New-Object Windows.Forms.TextBox; $ref.Multiline=$true; $ref.ReadOnly=$true; $ref.ScrollBars='Vertical'
$ref.Location='10,155'; $ref.Size='570,325'; $ref.Font = New-Object Drawing.Font('Consolas',8.5)
$ref.Text = @"
0x04 Restaurar tudo         0x05 Restaurar brilho/contr.   0x08 Restaurar cor
0x10 Brilho 0-100           0x12 Contraste 0-100           0x87 Nitidez 0-100
0x14 Preset de cor          0x16/0x18/0x1A Ganho R/G/B     0x20/0x30 Posicao H/V
0x60 Entrada: 06=HDMI 09=DisplayPort (proprietario Samsung; padrao seria 11/0F)
0xAA Orientacao (leitura)   0xB0 1=salvar 2=restaurar       0xB6 Tipo de painel
0xC8 Controlador            0xC9 Firmware                  0xCC Idioma OSD
0xD6 Energia 1=on 4=standby 5=off                          0xDC Modo de imagem
0xDF Versao MCCS            0xE0-0xFE proprietarios Samsung (desconhecidos)
"@
$tab4.Controls.Add($ref)

# ---------- Atualizacao ----------
$script:RefreshAll = {
  if ($script:Mon -eq [IntPtr]::Zero -and -not (Find-Monitor)) { $lblStatus.Text = 'Monitor nao encontrado (DDC/CI desligado ou fora do HDMI?)'; return }
  $r = Read-VCP 0x10
  if (-not $r.ok) { $script:Mon=[IntPtr]::Zero; if (-not (Find-Monitor)) { $lblStatus.Text='Monitor nao responde'; return } }
  foreach ($code in @($script:Sliders.Keys)) { $r = Read-VCP $code
    if ($r.ok) { $s=$script:Sliders[$code]; $s.tb.Maximum=[math]::Max(1,$r.max); $s.num.Maximum=$s.tb.Maximum
      $v=[math]::Min($r.cur,$s.tb.Maximum); $s.tb.Value=$v; $s.num.Value=$v } }
  foreach ($code in @($script:Combos.Keys)) { $r = Read-VCP $code
    if ($r.ok) { $c=$script:Combos[$code]; $i=[array]::IndexOf($c.keys,[int]$r.cur); $c.cb.SelectedIndex=$i } }
  $info = @()
  $map = [ordered]@{ 0xC9='Firmware'; 0xC8='Controlador'; 0xDF='Versao MCCS'; 0xB6='Tipo de painel (3=LCD TFT)'; 0xAA='Orientacao (1=paisagem)'; 0xD6='Energia'; 0x60='Entrada (leitura sempre 6 neste modelo)'; 0x02='New control value'; 0xC6='Application enable key'; 0xCA='0xCA'; 0xDB='0xDB'; 0xE9='0xE9'; 0xF5='0xF5'; 0xFE='0xFE' }
  foreach ($k in $map.Keys) { $r=Read-VCP $k; if ($r.ok) { $info += ("{0,-42} 0x{1:X2} = {2} (0x{2:X}), max {3}" -f $map[$k],$k,$r.cur,$r.max) } }
  $txtInfo.Text = ($info -join "`r`n")
  $lblStatus.Text = ("Atualizado {0:HH:mm:ss} - monitor LC34G55T respondendo" -f (Get-Date))
}
$btnRefresh.Add_Click({ & $script:RefreshAll })

# debounce dos sliders
$timer = New-Object Windows.Forms.Timer; $timer.Interval = 200
$timer.Add_Tick({ if ($script:Pending.Count -gt 0) { $p=$script:Pending; $script:Pending=@{}; foreach ($k in $p.Keys) { Write-VCP $k $p[$k].v $p[$k].d | Out-Null } } })
$timer.Start()

$form.Add_Shown({ Log 'Procurando monitor...'; if (Find-Monitor) { Log 'Monitor encontrado.' } else { Log 'Nenhum monitor com DDC/CI encontrado.' }; & $script:RefreshAll })
[void]$form.ShowDialog()
