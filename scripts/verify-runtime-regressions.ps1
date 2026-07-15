[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) "docs\dpi-evidence\runtime")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
public static class WeaverRegressionWin32 {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr value);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr value);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr value);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int length);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder text, int length);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("dwmapi.dll")] public static extern int DwmFlush();
    static bool Match(IntPtr hwnd, uint wantedPid, string wantedTitle) {
        uint pid; GetWindowThreadProcessId(hwnd, out pid);
        if (pid != wantedPid) return false;
        StringBuilder title = new StringBuilder(256); GetWindowText(hwnd, title, title.Capacity);
        return title.ToString() == wantedTitle;
    }
    public static IntPtr FindWindow(uint pid, string title) {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr ignored) {
            if (Match(hwnd, pid, title)) { result = hwnd; return false; }
            EnumChildWindows(hwnd, delegate(IntPtr child, IntPtr ignoredChild) {
                if (Match(child, pid, title)) { result = child; return false; }
                return true;
            }, IntPtr.Zero);
            return result == IntPtr.Zero;
        }, IntPtr.Zero);
        return result;
    }
    public static IntPtr FindGpuChild(IntPtr parent) {
        IntPtr result = IntPtr.Zero;
        EnumChildWindows(parent, delegate(IntPtr child, IntPtr ignored) {
            StringBuilder name = new StringBuilder(256); GetClassName(child, name, name.Capacity);
            if (name.ToString().Contains("GpuSurface")) { result = child; return false; }
            return true;
        }, IntPtr.Zero);
        return result;
    }
    public static long LParam(int x, int y) { return (long)(((y & 0xffff) << 16) | (x & 0xffff)); }
    public static void WriteTone(string path) {
        const int rate = 44100, seconds = 20, samples = rate * seconds;
        using (BinaryWriter writer = new BinaryWriter(File.Create(path))) {
            writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write(36 + samples * 2);
            writer.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); writer.Write(16); writer.Write((short)1);
            writer.Write((short)1); writer.Write(rate); writer.Write(rate * 2); writer.Write((short)2);
            writer.Write((short)16); writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write(samples * 2);
            for (int i = 0; i < samples; ++i)
                writer.Write((short)(Math.Sin(2.0 * Math.PI * 440.0 * i / rate) * 12000.0));
        }
    }
}
'@

$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$cli = Join-Path $RepoRoot "cli\dist\index.js"
$results = [ordered]@{ startedUtc=[DateTime]::UtcNow.ToString("o"); commands=@(); checks=@(); performance=@(); cadence=@(); events=@() }
$script:WeaverRegressionDevProcess=$null

function Check([string]$name, [bool]$passed, [string]$detail) {
    $results.checks += [pscustomobject]@{name=$name;passed=$passed;detail=$detail}
    if (-not $passed) { throw "${name}: ${detail}" }
}
function Run([string]$name, [string[]]$arguments) {
    $out = & $arguments[0] $arguments[1..($arguments.Count-1)]
    $code = $LASTEXITCODE
    foreach ($line in $out) { Write-Host $line }
    $results.commands += [pscustomobject]@{name=$name;command=($arguments -join " ");exitCode=$code}
    if ($code -ne 0) { throw "${name} failed with ${code}" }
}
function WaitFor([scriptblock]$condition, [string]$description, [int]$seconds=20) {
    $deadline=[DateTime]::UtcNow.AddSeconds($seconds)
    do { if (& $condition) { return }; Start-Sleep -Milliseconds 100 } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for ${description}"
}
function Status([string]$state) {
    $path=Join-Path $state "weaver\status.json"
    if (-not (Test-Path $path)) { return $null }
    try { Get-Content $path -Raw | ConvertFrom-Json } catch { $null }
}
function StartWidget([string]$runName,[string]$example,[bool]$software,[bool]$diagnostic=$false,[bool]$dev=$false) {
    $state=Join-Path $OutputDirectory "state-$runName"; [IO.Directory]::CreateDirectory($state)|Out-Null
    $env:LOCALAPPDATA=$state; $env:WEAVER_DPI_LOG=Join-Path $OutputDirectory "$runName-dpi-events.txt"
    if($software){$env:WEAVER_FORCE_SOFTWARE="1"}else{Remove-Item Env:WEAVER_FORCE_SOFTWARE -ErrorAction SilentlyContinue}
    if($diagnostic){$env:WEAVER_DPI_DIAGNOSTIC="1";$env:WEAVER_DPI_TEST_DPI="96"}else{Remove-Item Env:WEAVER_DPI_DIAGNOSTIC -ErrorAction SilentlyContinue;Remove-Item Env:WEAVER_DPI_TEST_DPI -ErrorAction SilentlyContinue}
    if($dev){
        $stdout=Join-Path $OutputDirectory "$runName-dev-stdout.txt"; $stderr=Join-Path $OutputDirectory "$runName-dev-stderr.txt"
        $process=Start-Process node -ArgumentList @($cli,"dev",$example) -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $script:WeaverRegressionDevProcess=$process
    }else{Run "$runName-install" @("node",$cli,"install",$example);$process=$null}
    WaitFor { $s=Status $state; if(-not $s){return $false}; $w=$s.widgets|Where-Object {$_.name -ne "renderer"}; return ($w -and $w.pid -gt 0 -and $w.state -eq "running") } "$runName running"
    $s=Status $state;$w=$s.widgets|Where-Object {$_.name -ne "renderer"};$title=$w.name
    $expected=if($software){"software"}else{"gpu"}
    WaitFor { $fresh=Status $state;if(-not $fresh){return $false};$live=$fresh.widgets|Where-Object {$_.name -eq $title};return($live.backend -eq $expected) } "$runName backend $expected"
    $s=Status $state;$w=$s.widgets|Where-Object {$_.name -eq $title};$hwnd=[WeaverRegressionWin32]::FindWindow([uint32]$w.pid,$title)
    Check "$runName-hwnd" ($hwnd-ne[IntPtr]::Zero) "pid=$($w.pid) hwnd=0x$('{0:x}'-f$hwnd.ToInt64())"
    [pscustomobject]@{Name=$runName;State=$state;Title=$title;Pid=[int]$w.pid;Hwnd=$hwnd;DevProcess=$process}
}
function StopWidget($run) {
    if(-not $run){return};$env:LOCALAPPDATA=$run.State;Run "$($run.Name)-down" @("node",$cli,"down")
    if($run.DevProcess -and -not $run.DevProcess.HasExited){Stop-Process -Id $run.DevProcess.Id -Force;Wait-Process -Id $run.DevProcess.Id -ErrorAction SilentlyContinue}
    if($run.DevProcess){$script:WeaverRegressionDevProcess=$null}
}
function Geometry([IntPtr]$hwnd){$r=New-Object WeaverRegressionWin32+RECT;[WeaverRegressionWin32]::GetClientRect($hwnd,[ref]$r)|Out-Null;[pscustomobject]@{Width=$r.Right-$r.Left;Height=$r.Bottom-$r.Top}}
function Capture([IntPtr]$hwnd,[string]$path){$r=New-Object WeaverRegressionWin32+RECT;$p=New-Object WeaverRegressionWin32+POINT;[WeaverRegressionWin32]::GetClientRect($hwnd,[ref]$r)|Out-Null;[WeaverRegressionWin32]::ClientToScreen($hwnd,[ref]$p)|Out-Null;$b=[Drawing.Bitmap]::new($r.Right,$r.Bottom);$g=[Drawing.Graphics]::FromImage($b);try{$g.CopyFromScreen($p.X,$p.Y,0,0,[Drawing.Size]::new($r.Right,$r.Bottom))}finally{$g.Dispose()};$b.Save($path,[Drawing.Imaging.ImageFormat]::Png);$b.Dispose()}
function SampleCpu([int]$processId,[int]$seconds,[string]$label){$p=Get-Process -Id $processId;$before=$p.TotalProcessorTime.TotalMilliseconds;$watch=[Diagnostics.Stopwatch]::StartNew();Start-Sleep -Seconds $seconds;$p=Get-Process -Id $processId;$watch.Stop();$cpu=100.0*($p.TotalProcessorTime.TotalMilliseconds-$before)/$watch.Elapsed.TotalMilliseconds;$results.performance += [pscustomobject]@{label=$label;pid=$processId;seconds=$watch.Elapsed.TotalSeconds;cpuOneCorePercent=[Math]::Round($cpu,3);privateMb=[Math]::Round($p.PrivateMemorySize64/1MB,3);handles=$p.HandleCount};return $cpu}
function RecordCadence([string]$state,[int]$widgetPid,[string]$label){$path=Join-Path $state "weaver\status.json.renderer.log";$line=Get-Content $path|Where-Object{$_-match " fps .* widget=$widgetPid frames=300 elapsed_ms=\d+"}|Select-Object -Last 1;if(-not$line-or$line-notmatch'elapsed_ms=(\d+)'){throw "No renderer cadence sample for $label"};$elapsed=[int64]$Matches[1];$fps=[Math]::Round(300000.0/$elapsed,3);$results.cadence += [pscustomobject]@{label=$label;widgetPid=$widgetPid;frames=300;elapsedMs=$elapsed;fps=$fps};Check "$label-frame-cadence" ($fps-ge55-and$fps-le65) "frames=300 elapsedMs=$elapsed fps=$fps"}
function Click([IntPtr]$child,[int]$x,[int]$y){$lp=[IntPtr]([WeaverRegressionWin32]::LParam($x,$y));[WeaverRegressionWin32]::SendMessage($child,0x0201,[UIntPtr]([uint32]1),$lp)|Out-Null;[WeaverRegressionWin32]::SendMessage($child,0x0202,[UIntPtr]([uint32]0),$lp)|Out-Null;Start-Sleep -Milliseconds 300}

$active=$null
$tonePlayer=$null
try {
    $active=StartWidget "mixed" (Join-Path $RepoRoot "examples\m4b-synthetic") $false $true
    $mixedPid=$active.Pid;$mixedHwnd=$active.Hwnd;$child=[WeaverRegressionWin32]::FindGpuChild($mixedHwnd)
    $renderer=(Status $active.State).widgets|Where-Object name -eq "renderer"
    $null=SampleCpu $mixedPid 10 "mixed-widget-100";$null=SampleCpu ([int]$renderer.pid) 10 "shared-renderer-100";RecordCadence $active.State $mixedPid "mixed-100"
    [WeaverRegressionWin32]::SendMessage($mixedHwnd,0x83D1,[UIntPtr]([uint32]144),[IntPtr]::Zero)|Out-Null
    WaitFor {$g=Geometry $mixedHwnd;return($g.Width-eq720-and$g.Height-eq480)} "mixed 150 percent"
    Check "mixed-transition-identity" ($mixedPid-eq$active.Pid-and$mixedHwnd-eq$active.Hwnd) "pid=$mixedPid hwnd=0x$('{0:x}'-f$mixedHwnd.ToInt64())"
    $null=SampleCpu $mixedPid 10 "mixed-widget-150";$renderer=(Status $active.State).widgets|Where-Object name -eq "renderer";$null=SampleCpu ([int]$renderer.pid) 10 "shared-renderer-150";RecordCadence $active.State $mixedPid "mixed-150"
    $oldRenderer=[int]$renderer.pid;Stop-Process -Id $oldRenderer -Force
    $backendFile=Get-ChildItem (Join-Path $active.State "weaver\status.json.backend-*")|Select-Object -First 1
    WaitFor { (Get-Content $backendFile.FullName -Raw).Trim() -eq "software" } "renderer demotion" 10
    Check "demotion-process-identity" ((Get-Process -Id $mixedPid)-and[WeaverRegressionWin32]::IsWindow($mixedHwnd)) "pid=$mixedPid hwnd=0x$('{0:x}'-f$mixedHwnd.ToInt64())"
    Capture $mixedHwnd (Join-Path $OutputDirectory "renderer-demotion-software.png")
    WaitFor {$s=Status $active.State;$r=$s.widgets|Where-Object name -eq "renderer";$w=$s.widgets|Where-Object name -eq $active.Title;return($r.pid-ne$oldRenderer-and$r.pid-gt0-and$w.backend-eq"gpu")} "renderer recovery" 20
    $newRenderer=[int]((Status $active.State).widgets|Where-Object name -eq "renderer").pid
    Check "recovery-process-identity" ((Get-Process -Id $mixedPid)-and[WeaverRegressionWin32]::IsWindow($mixedHwnd)) "widgetPid=$mixedPid hwnd=0x$('{0:x}'-f$mixedHwnd.ToInt64()) renderer=$oldRenderer->$newRenderer"
    Capture $mixedHwnd (Join-Path $OutputDirectory "renderer-recovery-gpu.png")
    $shell=New-Object -ComObject Shell.Application;$shell.MinimizeAll();Start-Sleep -Seconds 2
    Check "wind-window-survives" ([WeaverRegressionWin32]::IsWindow($mixedHwnd)) "pid=$mixedPid hwnd=0x$('{0:x}'-f$mixedHwnd.ToInt64())"
    Capture $mixedHwnd (Join-Path $OutputDirectory "wind-desktop-gpu.png");$shell.UndoMinimizeAll();Start-Sleep -Seconds 1
    StopWidget $active;$active=$null

    $active=StartWidget "clock" (Join-Path $RepoRoot "examples\clock") $true
    Capture $active.Hwnd (Join-Path $OutputDirectory "clock-forced-software.png");Check "clock-software" (((Status $active.State).widgets|Where-Object name -eq "Clock").backend-eq"software") "pid=$($active.Pid)"
    StopWidget $active;$active=$null

    $tonePath=Join-Path $OutputDirectory "visualizer-tone.wav";[WeaverRegressionWin32]::WriteTone($tonePath)
    $tonePlayer=New-Object System.Media.SoundPlayer($tonePath);$tonePlayer.PlayLooping();Start-Sleep -Milliseconds 500
    $active=StartWidget "visualizer" (Join-Path $RepoRoot "examples\visualizer") $false
    Capture $active.Hwnd (Join-Path $OutputDirectory "visualizer-shared-gpu.png");Check "visualizer-gpu" (((Status $active.State).widgets|Where-Object name -eq "Visualizer").backend-eq"gpu") "pid=$($active.Pid)"
    $null=SampleCpu $active.Pid 10 "visualizer-active";$tonePlayer.Stop();$tonePlayer=$null;StopWidget $active;$active=$null

    $active=StartWidget "idle" (Join-Path $RepoRoot "examples\m4b-parity") $false
    $idleRenderer=(Status $active.State).widgets|Where-Object name -eq "renderer";$idleRendererLog=Join-Path $active.State "weaver\status.json.renderer.log";Start-Sleep -Seconds 1;$idleBefore=(Get-Item $idleRendererLog).Length
    $null=SampleCpu $active.Pid 10 "fps-zero-widget";$null=SampleCpu ([int]$idleRenderer.pid) 10 "fps-zero-renderer";$idleAfter=(Get-Item $idleRendererLog).Length
    Check "fps-zero-idle-log" ($idleBefore-eq$idleAfter) "rendererLogBytes=$idleBefore->$idleAfter"
    StopWidget $active;$active=$null

    $devSource=Join-Path $RepoRoot "examples\.dpi-hot-swap";if(Test-Path $devSource){Remove-Item -LiteralPath $devSource -Recurse -Force};Copy-Item (Join-Path $RepoRoot "examples\dpi-diagnostic") $devSource -Recurse -Force
    $active=StartWidget "hot-swap" $devSource $false $false $true;$beforePid=$active.Pid;$beforeHwnd=$active.Hwnd;$devChild=[WeaverRegressionWin32]::FindGpuChild($beforeHwnd);$g=Geometry $beforeHwnd;Click $devChild ($g.Width-2) 100
    $sourcePath=Join-Path $devSource "widget.tsx";$source=[IO.File]::ReadAllText($sourcePath).Replace(">HIT<",">HOT<");[IO.File]::WriteAllText($sourcePath,$source)
    $widgetLog=Join-Path $active.State "weaver\logs\DPI Diagnostic.log"
    WaitFor {(Test-Path $widgetLog)-and((Get-Content $widgetLog -Raw)-match"dev hot swap applied \(preserved root hook state\)")} "state-preserving hot swap" 20
    Check "hot-swap-identity" ($beforePid-eq$active.Pid-and$beforeHwnd-eq$active.Hwnd-and[WeaverRegressionWin32]::IsWindow($beforeHwnd)) "pid=$beforePid hwnd=0x$('{0:x}'-f$beforeHwnd.ToInt64())"
    Capture $beforeHwnd (Join-Path $OutputDirectory "hot-swap-preserved.png");StopWidget $active;$active=$null
} finally {
    if($tonePlayer){$tonePlayer.Stop()}
    if($active){StopWidget $active}
    if($script:WeaverRegressionDevProcess -and -not $script:WeaverRegressionDevProcess.HasExited){Stop-Process -Id $script:WeaverRegressionDevProcess.Id -Force;Wait-Process -Id $script:WeaverRegressionDevProcess.Id -ErrorAction SilentlyContinue}
    & node $cli down 2>$null | Out-Null
    if(Test-Path (Join-Path $RepoRoot "examples\.dpi-hot-swap")){Remove-Item -LiteralPath (Join-Path $RepoRoot "examples\.dpi-hot-swap") -Recurse -Force}
    Remove-Item Env:WEAVER_FORCE_SOFTWARE -ErrorAction SilentlyContinue;Remove-Item Env:WEAVER_DPI_DIAGNOSTIC -ErrorAction SilentlyContinue;Remove-Item Env:WEAVER_DPI_TEST_DPI -ErrorAction SilentlyContinue
    $results.finishedUtc=[DateTime]::UtcNow.ToString("o");[IO.File]::WriteAllText((Join-Path $OutputDirectory "results.json"),($results|ConvertTo-Json -Depth 8))
}
Write-Host "Runtime regression verification passed."
