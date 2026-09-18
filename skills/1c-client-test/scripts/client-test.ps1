# Runtime test harness for the ordinary 1C:Enterprise thick/thin client.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$V8Path,
    [string]$InfoBasePath,
    [string]$InfoBaseServer,
    [string]$InfoBaseRef,
    [string]$UserName,
    [string]$Password,
    [string]$URL,
    [ValidateSet('Thick', 'Thin')]
    [string]$Client = 'Thick',
    [ValidateRange(0, 3600)]
    [int]$WaitReadySeconds = 300,
    [int]$AttachProcessId = 0,
    [string]$ScenarioPath,
    [string]$OutputDir,
    [switch]$KeepClient,
    [switch]$DisableStartupDialogs,
    [switch]$IncludeEventLog,
    [switch]$IncludeTechLog,
    [switch]$IncludeDumps,
    [switch]$ValidateScenarioOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class ClientTestWindowInfo {
    public long Handle { get; set; }
    public string Title { get; set; }
    public bool Visible { get; set; }
    public int Left { get; set; }
    public int Top { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
}

public static class ClientTestNative {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc proc, IntPtr param);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint source, uint target, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int command);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT point);

    public static ClientTestWindowInfo[] Enumerate(int wantedPid) {
        var result = new List<ClientTestWindowInfo>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr ignored) {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid != wantedPid) return true;
            RECT rect;
            if (!GetWindowRect(hWnd, out rect)) return true;
            var title = new StringBuilder(1024);
            GetWindowText(hWnd, title, title.Capacity);
            result.Add(new ClientTestWindowInfo {
                Handle = hWnd.ToInt64(), Title = title.ToString(), Visible = IsWindowVisible(hWnd),
                Left = rect.Left, Top = rect.Top, Width = rect.Right - rect.Left, Height = rect.Bottom - rect.Top
            });
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }

    public static void Click(int x, int y) {
        POINT oldPoint;
        GetCursorPos(out oldPoint);
        SetCursorPos(x, y);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        SetCursorPos(oldPoint.X, oldPoint.Y);
    }

    public static void Activate(IntPtr hWnd) {
        IntPtr foreground = GetForegroundWindow();
        uint ignored;
        uint foregroundThread = GetWindowThreadProcessId(foreground, out ignored);
        uint targetThread = GetWindowThreadProcessId(hWnd, out ignored);
        uint currentThread = GetCurrentThreadId();
        bool attachForeground = foregroundThread != 0 && foregroundThread != currentThread && AttachThreadInput(currentThread, foregroundThread, true);
        bool attachTarget = targetThread != 0 && targetThread != currentThread && targetThread != foregroundThread && AttachThreadInput(currentThread, targetThread, true);
        try {
            ShowWindow(hWnd, 9);
            BringWindowToTop(hWnd);
            SetForegroundWindow(hWnd);
            SetFocus(hWnd);
        } finally {
            if (attachTarget) AttachThreadInput(currentThread, targetThread, false);
            if (attachForeground) AttachThreadInput(currentThread, foregroundThread, false);
        }
    }

    public static void SendEscape(IntPtr hWnd) {
        PostMessage(hWnd, 0x0100, (IntPtr)0x1B, IntPtr.Zero);
        PostMessage(hWnd, 0x0101, (IntPtr)0x1B, IntPtr.Zero);
    }
}
'@

function Get-OptionalProperty {
    param($Object, [string]$Name, $Default = $null)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Find-ClientTestV8Project {
    param([string]$StartDir)
    $dir = [IO.Path]::GetFullPath($StartDir)
    for ($i = 0; $i -lt 20 -and $dir; $i++) {
        $candidate = Join-Path $dir '.v8-project.json'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
        $parent = [IO.Directory]::GetParent($dir)
        if ($null -eq $parent) { break }
        $dir = $parent.FullName
    }
    return $null
}

function Resolve-V8Executable {
    param([string]$Requested, [string]$Kind)
    $candidate = $Requested
    if (-not $candidate) {
        $projectFile = Find-ClientTestV8Project (Get-Location).Path
        if ($projectFile) {
            try { $candidate = (Get-Content -LiteralPath $projectFile -Raw -Encoding UTF8 | ConvertFrom-Json).v8path } catch {}
        }
    }
    if (-not $candidate) {
        $candidate = Get-ChildItem 'C:\Program Files\1cv8\*\bin\1cv8.exe','C:\Program Files (x86)\1cv8\*\bin\1cv8.exe' -ErrorAction SilentlyContinue |
            Sort-Object @{ Expression = {
                try { [version]$_.Directory.Parent.Name } catch { [version]'0.0' }
            }; Descending = $true }, @{ Expression = { $_.FullName }; Descending = $true } |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $candidate) { throw '1cv8 executable was not found; pass -V8Path.' }
    if (Test-Path -LiteralPath $candidate -PathType Container) { $candidate = Join-Path $candidate '1cv8.exe' }
    if ($Kind -eq 'Thin') { $candidate = Join-Path (Split-Path $candidate -Parent) '1cv8c.exe' }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "1C client executable not found: $candidate" }
    return [IO.Path]::GetFullPath($candidate)
}

function Get-ClientWindows {
    param([int]$ProcessId)
    return @([ClientTestNative]::Enumerate($ProcessId) | Where-Object { $_.Visible -and $_.Width -gt 0 -and $_.Height -gt 0 })
}

function Get-MainWindowInfo {
    param([int]$ProcessId)
    # Правка 1c-gui-test-kit (см. NOTICE.md): в оригинале
    # сначала берётся .NET Process.MainWindowHandle и только при его
    # отсутствии — самое большое видимое окно. Живой прогон на базе с
    # всплывающим окном «Ошибка применения расширения конфигурации»
    # (Бухгалтерия для Казахстана 3.0): .NET посчитал главным именно этот
    # маленький попап, и все screenshot/screenshotAfter после готовности
    # сняли попап 4.9 КБ вместо главного окна (initial.png при этом был
    # верным — его снимали по окну из собственного перечисления). Главное
    # окно толстого клиента — всегда самое большое видимое окно процесса;
    # MainWindowHandle оставлен только как разрешение ничьей по площади.
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $handle = $process.MainWindowHandle.ToInt64()
    $windows = Get-ClientWindows $ProcessId
    $window = $windows | Sort-Object `
        @{ Expression = { $_.Width * $_.Height }; Descending = $true }, `
        @{ Expression = { if ($_.Handle -eq $handle) { 0 } else { 1 } } } |
        Select-Object -First 1
    return $window
}

function Get-UiEntries {
    param([long]$Handle, [int]$MaxElements = 5000)
    $result = [Collections.Generic.List[object]]::new()
    try { $root = [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Handle) } catch { return @() }
    if ($null -eq $root) { return @() }
    $queue = [Collections.Generic.Queue[Windows.Automation.AutomationElement]]::new()
    $queue.Enqueue($root)
    $walker = [Windows.Automation.TreeWalker]::RawViewWalker
    while ($queue.Count -gt 0 -and $result.Count -lt $MaxElements) {
        $element = $queue.Dequeue()
        try {
            $current = $element.Current
            $bounds = $current.BoundingRectangle
            $patterns = [Collections.Generic.List[string]]::new()
            $patternObject = $null
            if ($element.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$patternObject)) { $patterns.Add('Toggle') }
            $patternObject = $null
            if ($element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$patternObject)) { $patterns.Add('Invoke') }
            $patternObject = $null
            if ($element.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$patternObject)) { $patterns.Add('SelectionItem') }
            $result.Add([pscustomobject]@{
                Element = $element
                Name = $current.Name
                AutomationId = $current.AutomationId
                ControlType = $current.ControlType.ProgrammaticName
                IsEnabled = $current.IsEnabled
                IsOffscreen = $current.IsOffscreen
                Left = [math]::Round($bounds.Left, 1)
                Top = [math]::Round($bounds.Top, 1)
                Width = [math]::Round($bounds.Width, 1)
                Height = [math]::Round($bounds.Height, 1)
                Patterns = @($patterns)
            })
            $child = $walker.GetFirstChild($element)
            while ($null -ne $child) {
                $queue.Enqueue($child)
                $child = $walker.GetNextSibling($child)
            }
        } catch {}
    }
    return @($result)
}

function Normalize-UiCaption {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return (($Value.Trim() -replace '[:：]\s*$', '').Trim())
}

function Find-UiEntry {
    param([int]$ProcessId, [string]$Name, [string]$WindowTitle = '')
    $normalizedName = Normalize-UiCaption $Name
    $candidates = @()
    foreach ($window in (Get-ClientWindows $ProcessId)) {
        if ($WindowTitle -and $window.Title -notmatch $WindowTitle) { continue }
        $matches = Get-UiEntries $window.Handle | Where-Object {
            $_.Name -and (
                $_.Name.Equals($Name, [StringComparison]::OrdinalIgnoreCase) -or
                (Normalize-UiCaption $_.Name).Equals($normalizedName, [StringComparison]::OrdinalIgnoreCase)
            )
        }
        foreach ($match in $matches) {
            $candidates += [pscustomobject]@{ Window = $window; Entry = $match }
        }
    }
    return $candidates | Sort-Object `
        @{ Expression = { if ($_.Entry.IsEnabled) { 0 } else { 1 } } }, `
        @{ Expression = { -$_.Entry.Patterns.Count } } | Select-Object -First 1
}

function Find-NearestUiEntry {
    param(
        [int]$ProcessId,
        [string]$AnchorName,
        [string]$TargetName = '',
        [string]$WindowTitle = '',
        [string]$ControlType = '',
        [string]$Pattern = '',
        [string]$Relation = '',
        [double]$MaxDistance = 0
    )
    $anchor = Find-UiEntry $ProcessId $AnchorName $WindowTitle
    if (-not $anchor) { return $null }
    if ($ControlType -and -not $ControlType.StartsWith('ControlType.')) { $ControlType = 'ControlType.' + $ControlType }
    $normalizedTargetName = Normalize-UiCaption $TargetName
    $anchorLeft = $anchor.Entry.Left
    $anchorTop = $anchor.Entry.Top
    $anchorRight = $anchor.Entry.Left + $anchor.Entry.Width
    $anchorBottom = $anchor.Entry.Top + $anchor.Entry.Height
    $candidates = @(Get-UiEntries $anchor.Window.Handle | Where-Object {
        (-not $TargetName -or (Normalize-UiCaption $_.Name).Equals($normalizedTargetName, [StringComparison]::OrdinalIgnoreCase)) -and
        (-not $ControlType -or $_.ControlType -eq $ControlType) -and
        (-not $Pattern -or $_.Patterns -contains $Pattern) -and
        (-not $Relation -or
            ($Relation -eq 'below' -and $_.Top -ge $anchorBottom) -or
            ($Relation -eq 'above' -and ($_.Top + $_.Height) -le $anchorTop) -or
            ($Relation -eq 'right' -and $_.Left -ge $anchorRight) -or
            ($Relation -eq 'left' -and ($_.Left + $_.Width) -le $anchorLeft)) -and
        -not $_.IsOffscreen -and $_.Width -gt 0 -and $_.Height -gt 0 -and
        -not [double]::IsInfinity([double]$_.Left) -and -not [double]::IsInfinity([double]$_.Top)
    })
    $anchorX = $anchorLeft + ($anchor.Entry.Width / 2)
    $anchorY = $anchorTop + ($anchor.Entry.Height / 2)
    $nearest = $candidates | Sort-Object {
        $candidateX = $_.Left + ($_.Width / 2)
        $candidateY = $_.Top + ($_.Height / 2)
        [math]::Sqrt([math]::Pow($candidateX - $anchorX, 2) + [math]::Pow($candidateY - $anchorY, 2))
    } | Select-Object -First 1
    if ($nearest -and $MaxDistance -gt 0) {
        $distance = [math]::Sqrt(
            [math]::Pow(($nearest.Left + $nearest.Width / 2) - $anchorX, 2) +
            [math]::Pow(($nearest.Top + $nearest.Height / 2) - $anchorY, 2)
        )
        if ($distance -gt $MaxDistance) { $nearest = $null }
    }
    if (-not $nearest) { return $null }
    return [pscustomobject]@{ Window = $anchor.Window; Anchor = $anchor.Entry; Entry = $nearest }
}

function Wait-ClientTestCondition {
    param([scriptblock]$Condition, [int]$TimeoutSeconds = 0, [int]$PollMilliseconds = 250)
    $deadline = (Get-Date).AddSeconds([math]::Max(0, $TimeoutSeconds))
    do {
        if (& $Condition) { return $true }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds $PollMilliseconds
    } while ($true)
    return $false
}

function Wait-ClientTestValue {
    param([scriptblock]$Probe, [int]$TimeoutSeconds = 0, [int]$PollMilliseconds = 250)
    $deadline = (Get-Date).AddSeconds([math]::Max(0, $TimeoutSeconds))
    do {
        $value = & $Probe
        if ($null -ne $value) { return $value }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds $PollMilliseconds
    } while ($true)
    return $null
}

function Resolve-UiTargetForPattern {
    param($Target, [string]$PatternName)
    if (-not $Target) { return $null }
    if ($Target.Entry.Patterns -contains $PatternName) { return $Target }
    $label = $Target.Entry
    $candidates = @(Get-UiEntries $Target.Window.Handle | Where-Object { $_.Patterns -contains $PatternName -and -not $_.IsOffscreen })
    if ($candidates.Count -eq 0) { return $Target }
    $labelX = $label.Left + ($label.Width / 2)
    $labelY = $label.Top + ($label.Height / 2)
    $nearest = $candidates | Sort-Object {
        $candidateX = $_.Left + ($_.Width / 2)
        $candidateY = $_.Top + ($_.Height / 2)
        [math]::Sqrt([math]::Pow($candidateX - $labelX, 2) + [math]::Pow($candidateY - $labelY, 2))
    } | Select-Object -First 1
    if ($nearest) { return [pscustomobject]@{ Window=$Target.Window; Entry=$nearest; MatchedByLabel=$label.Name } }
    return $Target
}

function Find-MatchingWindows {
    param([int]$ProcessId, [string]$TitlePattern = '.*', [string]$ContainsElement = '')
    # Do not use $Matches here: it is PowerShell's automatic regex-capture variable.
    $matchingWindows = @()
    foreach ($window in (Get-ClientWindows $ProcessId)) {
        if ($window.Title -notmatch $TitlePattern) { continue }
        if ($ContainsElement) {
            $found = Get-UiEntries $window.Handle | Where-Object { $_.Name -match $ContainsElement } | Select-Object -First 1
            if (-not $found) { continue }
        }
        $matchingWindows += $window
    }
    return $matchingWindows
}

function Save-WindowScreenshot {
    param([long]$Handle, [string]$Path)
    $window = Get-ClientWindows $script:clientProcess.Id | Where-Object { $_.Handle -eq $Handle } | Select-Object -First 1
    if (-not $window) { throw "Window handle $Handle is not available for screenshot." }
    $parent = Split-Path $Path -Parent
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [ClientTestNative]::Activate([IntPtr]$Handle)
    Start-Sleep -Milliseconds 100
    $window = Get-ClientWindows $script:clientProcess.Id | Where-Object { $_.Handle -eq $Handle } | Select-Object -First 1
    $bitmap = [Drawing.Bitmap]::new($window.Width, $window.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $hdc = $graphics.GetHdc()
        try { $rendered = [ClientTestNative]::PrintWindow([IntPtr]$Handle, $hdc, 2) } finally { $graphics.ReleaseHdc($hdc) }
        if (-not $rendered) { $graphics.CopyFromScreen($window.Left, $window.Top, 0, 0, [Drawing.Size]::new($window.Width, $window.Height)) }
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Save-UiDump {
    param([string]$Path)
    $parent = Split-Path $Path -Parent
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $dump = foreach ($window in (Get-ClientWindows $script:clientProcess.Id)) {
        [pscustomobject]@{
            Window = $window
            Elements = @(Get-UiEntries $window.Handle | Select-Object Name,AutomationId,ControlType,IsEnabled,IsOffscreen,Left,Top,Width,Height,Patterns)
        }
    }
    $dump | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-UiAction {
    param($Entry, [long]$WindowHandle, [ValidateSet('Invoke','Toggle','Select','Click')] [string]$Operation, [string]$DesiredState = '')
    $element = $Entry.Element
    [ClientTestNative]::Activate([IntPtr]$WindowHandle)
    Start-Sleep -Milliseconds 200
    if ($Operation -eq 'Toggle') {
        $pattern = $null
        if (-not $element.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) {
            throw "UI element '$($Entry.Name)' does not support TogglePattern."
        }
        $before = $pattern.Current.ToggleState.ToString()
        if (-not $DesiredState -or $before -ne $DesiredState) { $pattern.Toggle() }
        Start-Sleep -Milliseconds 500
        $after = $pattern.Current.ToggleState.ToString()
        if ($DesiredState -and $after -ne $DesiredState) { throw "Toggle '$($Entry.Name)' is '$after', expected '$DesiredState'." }
        return
    }
    if ($Operation -eq 'Invoke') {
        $pattern = $null
        if ($element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke(); return }
    }
    if ($Operation -eq 'Select') {
        $pattern = $null
        if ($element.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
            $pattern.Select()
            Start-Sleep -Milliseconds 300
            if ($pattern.Current.IsSelected) { return }
        }
    }
    try {
        $point = $element.GetClickablePoint()
        [ClientTestNative]::Click([int]$point.X, [int]$point.Y)
    } catch {
        throw "UI element '$($Entry.Name)' has no supported action or clickable point."
    }
}

function Write-JsonFile {
    param($Value, [string]$Path, [int]$Depth = 8)
    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Resolve-ClientTestArtifactPath {
    param([string]$File)
    if ([string]::IsNullOrWhiteSpace($File)) { throw 'Artifact file name cannot be empty.' }
    if (@($File -split '[\\/]' | Where-Object { $_ -eq '..' }).Count -gt 0) {
        throw "Artifact path cannot contain '..': '$File'."
    }
    $root = [IO.Path]::GetFullPath($script:outputRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidate = if ([IO.Path]::IsPathRooted($File)) {
        [IO.Path]::GetFullPath($File)
    } else {
        [IO.Path]::GetFullPath((Join-Path $root $File))
    }
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if ($candidate.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        -not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Artifact path must stay inside OutputDir: '$File'."
    }
    $relativePath = $candidate.Substring($prefix.Length)
    foreach ($segment in $relativePath.Split(@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "Artifact path contains invalid file-name characters: '$File'."
        }
    }
    return $candidate
}

function Test-ClientTestRegex {
    param([string]$Pattern, [string]$Field, [int]$ActionIndex)
    if ([string]::IsNullOrEmpty($Pattern)) { return }
    try { [regex]::new($Pattern) | Out-Null }
    catch { throw "Action $ActionIndex has invalid regex in '$Field': $($_.Exception.Message)" }
}

function Get-RequiredClientTestText {
    param($Action, [string]$Field, [int]$ActionIndex)
    $value = [string](Get-OptionalProperty $Action $Field '')
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Action $ActionIndex requires '$Field'." }
    return $value
}

function Test-ClientTestBooleanProperty {
    param($Action, [string]$Field, [int]$ActionIndex)
    $property = $Action.PSObject.Properties[$Field]
    if ($null -ne $property -and $property.Value -isnot [bool]) {
        throw "Action $ActionIndex '$Field' must be a JSON boolean."
    }
}

function Test-ClientTestScenario {
    param($Scenario)
    if ($null -eq $Scenario -or $null -eq $Scenario.PSObject.Properties['actions']) {
        throw "Scenario root must contain an 'actions' array."
    }
    $supported = @(
        'wait','screenshot','dumpUi','assertWindow','assertNoWindow','dismissWindow',
        'invoke','select','clickElement','clickNearest','assertNearest','assertNoNearest',
        'toggle','assertToggle','assertElement','assertNoElement','clickRelative','sendKeys'
    )
    $actions = @($Scenario.actions)
    for ($index = 0; $index -lt $actions.Count; $index++) {
        $action = $actions[$index]
        $number = $index + 1
        $type = [string](Get-OptionalProperty $action 'type' '')
        if ($type -notin $supported) { throw "Action $number has unknown type '$type'." }
        $label = [string](Get-OptionalProperty $action 'name' ("{0:D2}-{1}" -f $number, $type))

        $timeoutProperty = $action.PSObject.Properties['timeoutSeconds']
        if ($null -ne $timeoutProperty) {
            try { $timeout = [double]$timeoutProperty.Value } catch { throw "Action $number has invalid timeoutSeconds." }
            if ([double]::IsNaN($timeout) -or [double]::IsInfinity($timeout) -or $timeout -lt 0 -or $timeout -gt 3600 -or $timeout -ne [math]::Floor($timeout)) {
                throw "Action $number timeoutSeconds must be an integer from 0 to 3600."
            }
        }
        Test-ClientTestBooleanProperty $action 'screenshotAfter' $number
        Test-ClientTestBooleanProperty $action 'optional' $number
        Test-ClientTestBooleanProperty $action 'visible' $number

        if ($action.PSObject.Properties['windowTitle']) {
            Test-ClientTestRegex ([string]$action.windowTitle) 'windowTitle' $number
        }
        if ($type -in @('assertWindow','assertNoWindow','dismissWindow')) {
            Test-ClientTestRegex ([string](Get-OptionalProperty $action 'title' '.*')) 'title' $number
            Test-ClientTestRegex ([string](Get-OptionalProperty $action 'containsElement' '')) 'containsElement' $number
        }
        if ($type -eq 'dismissWindow') {
            $dismissTitle = [string](Get-OptionalProperty $action 'title' '')
            $dismissContains = [string](Get-OptionalProperty $action 'containsElement' '')
            if ([string]::IsNullOrWhiteSpace($dismissContains) -and
                ([string]::IsNullOrWhiteSpace($dismissTitle) -or $dismissTitle -in @('.*','^.*$'))) {
                throw "Action $number dismissWindow requires a specific 'title' or 'containsElement'."
            }
        }
        if ($type -eq 'screenshot') {
            Resolve-ClientTestArtifactPath ([string](Get-OptionalProperty $action 'file' ($label + '.png'))) | Out-Null
        }
        if ($type -eq 'dumpUi') {
            Resolve-ClientTestArtifactPath ([string](Get-OptionalProperty $action 'file' ($label + '-ui.json'))) | Out-Null
        }
        if ([bool](Get-OptionalProperty $action 'screenshotAfter' $false)) {
            Resolve-ClientTestArtifactPath ($label + '.png') | Out-Null
        }
        if ($type -eq 'wait') {
            try { $milliseconds = [double](Get-OptionalProperty $action 'milliseconds' 500) } catch { throw "Action $number has invalid milliseconds." }
            if ([double]::IsNaN($milliseconds) -or [double]::IsInfinity($milliseconds) -or $milliseconds -lt 0 -or $milliseconds -gt 3600000 -or $milliseconds -ne [math]::Floor($milliseconds)) {
                throw "Action $number milliseconds must be an integer from 0 to 3600000."
            }
        }
        if ($type -eq 'clickNearest') {
            Get-RequiredClientTestText $action 'anchorAutomationName' $number | Out-Null
            Get-RequiredClientTestText $action 'automationName' $number | Out-Null
        }
        if ($type -in @('assertNearest','assertNoNearest')) {
            Get-RequiredClientTestText $action 'anchorAutomationName' $number | Out-Null
        }
        if ($action.PSObject.Properties['maxDistance']) {
            try { $maxDistance = [double]$action.maxDistance } catch { throw "Action $number has invalid maxDistance." }
            if ([double]::IsNaN($maxDistance) -or [double]::IsInfinity($maxDistance) -or $maxDistance -lt 0) {
                throw "Action $number maxDistance must be a non-negative finite number."
            }
        }
        if ($type -in @('invoke','select','clickElement','toggle','assertToggle','assertElement','assertNoElement')) {
            Get-RequiredClientTestText $action 'automationName' $number | Out-Null
        }
        if ($type -eq 'clickRelative') {
            if ($null -eq $action.PSObject.Properties['x'] -or $null -eq $action.PSObject.Properties['y']) {
                throw "Action $number requires 'x' and 'y'."
            }
            try { $x = [double]$action.x; $y = [double]$action.y } catch { throw "Action $number has invalid x or y." }
            if ([double]::IsNaN($x) -or [double]::IsInfinity($x) -or [double]::IsNaN($y) -or [double]::IsInfinity($y)) {
                throw "Action $number x and y must be finite numbers."
            }
        }
        if ($type -eq 'sendKeys') { Get-RequiredClientTestText $action 'keys' $number | Out-Null }
        if ($action.PSObject.Properties['state']) {
            $state = [string]$action.state
            if ($state -notin @('On','Off','Indeterminate')) { throw "Action $number has invalid state '$state'." }
        }
        if ($action.PSObject.Properties['pattern']) {
            $pattern = [string]$action.pattern
            if ($pattern -notin @('Invoke','Toggle','SelectionItem')) { throw "Action $number has invalid pattern '$pattern'." }
        }
        if ($action.PSObject.Properties['relation']) {
            $relation = [string]$action.relation
            if ($relation -notin @('below','above','left','right')) { throw "Action $number has invalid relation '$relation'." }
        }
    }
    return $actions
}

function Copy-ClientDiagnostics {
    param([int]$ProcessId, [datetime]$Since, [string]$Destination, [switch]$TechLog, [switch]$Dumps)
    $local1C = Join-Path $env:LOCALAPPDATA '1C\1cv8'
    if ($TechLog) {
        $logRoot = Join-Path $local1C 'logs'
        foreach ($prefix in @('1cv8_', '1cv8c_')) {
            $source = Join-Path $logRoot ($prefix + $ProcessId)
            if (Test-Path -LiteralPath $source -PathType Container) {
                $target = Join-Path $Destination ('tech-log\' + (Split-Path $source -Leaf))
                New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
                Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
            }
        }
    }
    $dumpRoot = Join-Path $local1C 'dumps'
    if ($Dumps -and (Test-Path -LiteralPath $dumpRoot -PathType Container)) {
        $pidToken = '(^|[^0-9])' + [regex]::Escape([string]$ProcessId) + '([^0-9]|$)'
        $freshDumps = @(Get-ChildItem -LiteralPath $dumpRoot -File -ErrorAction SilentlyContinue | Where-Object {
            $_.LastWriteTime -ge $Since -and $_.Name -match $pidToken
        })
        if ($freshDumps.Count -gt 0) {
            $target = Join-Path $Destination 'dumps'
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            $freshDumps | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $target -Force }
        }
    }
}

$startedAt = Get-Date
if (-not $OutputDir) { $OutputDir = Join-Path (Get-Location) ('build\1c-client-test-' + $startedAt.ToString('yyyyMMdd-HHmmss')) }
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$script:outputRoot = $OutputDir
$scenario = $null
$actions = @()
try {
    if ($ScenarioPath) {
        if (-not (Test-Path -LiteralPath $ScenarioPath -PathType Leaf)) { throw "Scenario not found: $ScenarioPath" }
        $scenario = Get-Content -LiteralPath $ScenarioPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $actions = @(Test-ClientTestScenario $scenario)
    } elseif ($ValidateScenarioOnly) {
        throw 'ValidateScenarioOnly requires ScenarioPath.'
    }
} catch {
    [Console]::Error.WriteLine("[ERROR] Scenario validation failed: $($_.Exception.Message)")
    exit 1
}
if ($ValidateScenarioOnly) {
    Write-Host "[OK] Scenario is valid ($($actions.Count) actions)." -ForegroundColor Green
    exit 0
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$steps = [Collections.Generic.List[object]]::new()
$failures = [Collections.Generic.List[string]]::new()
$startedByHarness = $false
$script:clientProcess = $null
$readyAt = $null
$currentStage = 'startup'

try {
    if ($AttachProcessId -gt 0) {
        $script:clientProcess = Get-Process -Id $AttachProcessId -ErrorAction Stop
    } else {
        if (-not $InfoBasePath -and (-not $InfoBaseServer -or -not $InfoBaseRef)) {
            throw 'Pass -InfoBasePath or -InfoBaseServer with -InfoBaseRef.'
        }
        $exe = Resolve-V8Executable $V8Path $Client
        $arguments = [Collections.Generic.List[string]]::new()
        $arguments.Add('ENTERPRISE')
        if ($InfoBasePath) { $arguments.Add('/F"' + [IO.Path]::GetFullPath($InfoBasePath) + '"') }
        else { $arguments.Add('/S"' + $InfoBaseServer + '\' + $InfoBaseRef + '"') }
        if ($UserName) { $arguments.Add('/N"' + $UserName + '"') }
        if ($Password) { $arguments.Add('/P"' + $Password + '"') }
        if ($URL) { $arguments.Add('/URL"' + $URL + '"') }
        if ($DisableStartupDialogs) { $arguments.Add('/DisableStartupDialogs') }
        $script:clientProcess = Start-Process -FilePath $exe -ArgumentList ($arguments -join ' ') -WindowStyle Normal -PassThru
        $startedByHarness = $true
    }

    $deadline = (Get-Date).AddSeconds($WaitReadySeconds)
    do {
        Start-Sleep -Milliseconds 500
        $script:clientProcess.Refresh()
        if ($script:clientProcess.HasExited) { throw "1C client exited before readiness (code $($script:clientProcess.ExitCode))." }
        $mainWindow = Get-MainWindowInfo $script:clientProcess.Id
        $ready = $null -ne $mainWindow -and $script:clientProcess.Responding -and $mainWindow.Title -notmatch 'Загрузка конфигурационной информации|Loading configuration information'
    } while (-not $ready -and (Get-Date) -lt $deadline)
    if (-not $ready) { throw "1C client did not become ready in $WaitReadySeconds seconds." }

    $readyAt = Get-Date
    $currentStage = 'scenario'
    Write-Host "[READY] PID $($script:clientProcess.Id): $($mainWindow.Title)" -ForegroundColor Green
    Save-WindowScreenshot $mainWindow.Handle (Join-Path $OutputDir 'initial.png')

    for ($index = 0; $index -lt $actions.Count; $index++) {
        $action = $actions[$index]
        $type = [string](Get-OptionalProperty $action 'type' '')
        $label = [string](Get-OptionalProperty $action 'name' ("{0:D2}-{1}" -f ($index + 1), $type))
        $timeoutSeconds = [int](Get-OptionalProperty $action 'timeoutSeconds' 0)
        $stepStart = Get-Date
        try {
            switch ($type) {
                'wait' { Start-Sleep -Milliseconds ([int](Get-OptionalProperty $action 'milliseconds' 500)) }
                'screenshot' {
                    $file = [string](Get-OptionalProperty $action 'file' ($label + '.png'))
                    $mainWindow = Get-MainWindowInfo $script:clientProcess.Id
                    Save-WindowScreenshot $mainWindow.Handle (Resolve-ClientTestArtifactPath $file)
                }
                'dumpUi' { Save-UiDump (Resolve-ClientTestArtifactPath ([string](Get-OptionalProperty $action 'file' ($label + '-ui.json')))) }
                { $_ -in @('assertWindow','assertNoWindow') } {
                    $title = [string](Get-OptionalProperty $action 'title' '.*')
                    $contains = [string](Get-OptionalProperty $action 'containsElement' '')
                    $windowCondition = {
                        $count = @(Find-MatchingWindows $script:clientProcess.Id $title $contains).Count
                        if ($type -eq 'assertWindow') { return $count -gt 0 }
                        return $count -eq 0
                    }
                    if (-not (Wait-ClientTestCondition $windowCondition $timeoutSeconds)) {
                        if ($type -eq 'assertWindow') { throw "Expected window not found: title='$title', contains='$contains'." }
                        throw "Unexpected window found: title='$title', contains='$contains'."
                    }
                }
                'dismissWindow' {
                    $title = [string](Get-OptionalProperty $action 'title' '.*')
                    $contains = [string](Get-OptionalProperty $action 'containsElement' '')
                    $buttonName = [string](Get-OptionalProperty $action 'buttonName' 'Закрыть')
                    $candidateWindows = @(Find-MatchingWindows $script:clientProcess.Id $title $contains)
                    if ($candidateWindows.Count -eq 0 -and $timeoutSeconds -gt 0) {
                        Wait-ClientTestCondition { @(Find-MatchingWindows $script:clientProcess.Id $title $contains).Count -gt 0 } $timeoutSeconds | Out-Null
                        $candidateWindows = @(Find-MatchingWindows $script:clientProcess.Id $title $contains)
                    }
                    $modalIndex = 0
                    foreach ($window in $candidateWindows) {
                        if (@(Find-MatchingWindows $script:clientProcess.Id $title $contains).Count -eq 0) { break }
                        $modalIndex++
                        Save-WindowScreenshot $window.Handle (Join-Path $OutputDir ('modal-before-dismiss-{0:D2}-{1:D2}.png' -f ($index + 1), $modalIndex))
                        $button = Get-UiEntries $window.Handle | Where-Object { $_.Name -and $_.Name.Equals($buttonName, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
                        if ($button) { Invoke-UiAction $button $window.Handle 'Click' }
                        else { [ClientTestNative]::SendEscape([IntPtr]$window.Handle) }
                        Start-Sleep -Milliseconds 500
                        $stillPresent = @(Find-MatchingWindows $script:clientProcess.Id $title $contains).Count -gt 0
                        if ($stillPresent) {
                            [ClientTestNative]::SendEscape([IntPtr]$window.Handle)
                            Start-Sleep -Milliseconds 500
                        }
                    }
                    $dismissed = Wait-ClientTestCondition {
                        @(Find-MatchingWindows $script:clientProcess.Id $title $contains).Count -eq 0
                    } $timeoutSeconds
                    if (-not $dismissed) {
                        throw "Known window was not dismissed: title='$title', contains='$contains'."
                    }
                }
                'clickNearest' {
                    $anchorName = [string](Get-OptionalProperty $action 'anchorAutomationName' '')
                    $targetName = [string](Get-OptionalProperty $action 'automationName' '')
                    $windowTitle = [string](Get-OptionalProperty $action 'windowTitle' '')
                    $requiredPattern = [string](Get-OptionalProperty $action 'pattern' '')
                    $nearestProbe = {
                        Find-NearestUiEntry $script:clientProcess.Id $anchorName $targetName $windowTitle '' $requiredPattern
                    }
                    $nearestTarget = Wait-ClientTestValue $nearestProbe $timeoutSeconds
                    if (-not $nearestTarget) {
                        $anchor = Find-UiEntry $script:clientProcess.Id $anchorName $windowTitle
                        if (-not $anchor -and [bool](Get-OptionalProperty $action 'optional' $false)) { break }
                        if (-not $anchor) { throw "Anchor UI element not found: '$anchorName'." }
                        throw "No visible '$targetName' element was found near '$anchorName'."
                    }
                    Invoke-UiAction $nearestTarget.Entry $nearestTarget.Window.Handle 'Click'
                }
                { $_ -in @('assertNearest','assertNoNearest') } {
                    $anchorName = [string](Get-OptionalProperty $action 'anchorAutomationName' '')
                    $windowTitle = [string](Get-OptionalProperty $action 'windowTitle' '')
                    $targetName = [string](Get-OptionalProperty $action 'automationName' '')
                    $controlType = [string](Get-OptionalProperty $action 'controlType' '')
                    $requiredPattern = [string](Get-OptionalProperty $action 'pattern' '')
                    $relation = [string](Get-OptionalProperty $action 'relation' '')
                    $maxDistance = [double](Get-OptionalProperty $action 'maxDistance' 0)
                    $nearestProbe = {
                        Find-NearestUiEntry $script:clientProcess.Id $anchorName $targetName $windowTitle $controlType $requiredPattern $relation $maxDistance
                    }
                    if ($type -eq 'assertNearest') {
                        $nearestTarget = Wait-ClientTestValue $nearestProbe $timeoutSeconds
                        if ($nearestTarget) { break }
                        if (-not (Find-UiEntry $script:clientProcess.Id $anchorName $windowTitle)) { throw "Anchor UI element not found: '$anchorName'." }
                        throw "Expected nearby UI element was not found near '$anchorName'."
                    }
                    $anchorProbe = { Find-UiEntry $script:clientProcess.Id $anchorName $windowTitle }
                    if (-not (Wait-ClientTestValue $anchorProbe $timeoutSeconds)) { throw "Anchor UI element not found: '$anchorName'." }
                    if (-not (Wait-ClientTestCondition { $null -eq (& $nearestProbe) } $timeoutSeconds)) {
                        throw "Unexpected nearby UI element was found near '$anchorName'."
                    }
                }
                { $_ -in @('assertElement','assertNoElement','assertToggle','toggle','invoke','select','clickElement') } {
                    $automationName = [string](Get-OptionalProperty $action 'automationName' '')
                    $windowTitle = [string](Get-OptionalProperty $action 'windowTitle' '')
                    $targetProbe = { Find-UiEntry $script:clientProcess.Id $automationName $windowTitle }
                    if ($type -eq 'assertNoElement') {
                        if (-not (Wait-ClientTestCondition { $null -eq (& $targetProbe) } $timeoutSeconds)) {
                            throw "Unexpected UI element found: '$automationName'."
                        }
                        break
                    }
                    $target = Wait-ClientTestValue $targetProbe $timeoutSeconds
                    if (-not $target) { throw "UI element not found: '$automationName'." }
                    if ($type -in @('assertToggle','toggle')) { $target = Resolve-UiTargetForPattern $target 'Toggle' }
                    if ($type -eq 'assertElement') {
                        $visible = [bool](Get-OptionalProperty $action 'visible' $false)
                        if ($visible) {
                            $visibleProbe = {
                                $currentTarget = Find-UiEntry $script:clientProcess.Id $automationName $windowTitle
                                return $null -ne $currentTarget -and -not $currentTarget.Entry.IsOffscreen
                            }
                            if (-not (Wait-ClientTestCondition $visibleProbe $timeoutSeconds)) { throw "UI element '$automationName' is offscreen." }
                        }
                    } elseif ($type -eq 'assertToggle') {
                        $pattern = $null
                        if (-not $target.Entry.Element.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) { throw "'$automationName' has no TogglePattern." }
                        $desired = [string](Get-OptionalProperty $action 'state' '')
                        if ($desired) {
                            $stateProbe = {
                                $currentTarget = Find-UiEntry $script:clientProcess.Id $automationName $windowTitle
                                if (-not $currentTarget) { return $false }
                                $currentTarget = Resolve-UiTargetForPattern $currentTarget 'Toggle'
                                $currentPattern = $null
                                if (-not $currentTarget.Entry.Element.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$currentPattern)) { return $false }
                                return $currentPattern.Current.ToggleState.ToString() -eq $desired
                            }
                            if (-not (Wait-ClientTestCondition $stateProbe $timeoutSeconds)) {
                                $actual = $pattern.Current.ToggleState.ToString()
                                throw "Toggle '$automationName' is '$actual', expected '$desired'."
                            }
                        }
                    } elseif ($type -eq 'toggle') {
                        Invoke-UiAction $target.Entry $target.Window.Handle 'Toggle' ([string](Get-OptionalProperty $action 'state' ''))
                    } elseif ($type -eq 'invoke') { Invoke-UiAction $target.Entry $target.Window.Handle 'Invoke' }
                    elseif ($type -eq 'select') { Invoke-UiAction $target.Entry $target.Window.Handle 'Select' }
                    else { Invoke-UiAction $target.Entry $target.Window.Handle 'Click' }
                }
                'clickRelative' {
                    $title = [string](Get-OptionalProperty $action 'windowTitle' '')
                    $windowProbe = {
                        if ($title) { return Find-MatchingWindows $script:clientProcess.Id $title '' | Select-Object -First 1 }
                        return Get-MainWindowInfo $script:clientProcess.Id
                    }
                    $window = Wait-ClientTestValue $windowProbe $timeoutSeconds
                    if (-not $window) { throw "Window not found for relative click: '$title'." }
                    $x = [double](Get-OptionalProperty $action 'x' 0)
                    $y = [double](Get-OptionalProperty $action 'y' 0)
                    if ($x -ge 0 -and $x -le 1) { $x = $window.Left + $window.Width * $x } else { $x += $window.Left }
                    if ($y -ge 0 -and $y -le 1) { $y = $window.Top + $window.Height * $y } else { $y += $window.Top }
                    [ClientTestNative]::Activate([IntPtr]$window.Handle)
                    [ClientTestNative]::Click([int]$x, [int]$y)
                }
                'sendKeys' {
                    $mainWindow = Get-MainWindowInfo $script:clientProcess.Id
                    [ClientTestNative]::Activate([IntPtr]$mainWindow.Handle)
                    [Windows.Forms.SendKeys]::SendWait([string](Get-OptionalProperty $action 'keys' ''))
                }
                default { throw "Unknown scenario action: '$type'." }
            }
            $screenshotAfter = [bool](Get-OptionalProperty $action 'screenshotAfter' $false)
            if ($screenshotAfter) {
                $mainWindow = Get-MainWindowInfo $script:clientProcess.Id
                Save-WindowScreenshot $mainWindow.Handle (Resolve-ClientTestArtifactPath ($label + '.png'))
            }
            $steps.Add([pscustomobject]@{ Index=$index+1; Name=$label; Type=$type; Status='passed'; DurationMs=[int]((Get-Date)-$stepStart).TotalMilliseconds })
            Write-Host "[PASS] $label"
        } catch {
            $message = $_.Exception.Message
            $steps.Add([pscustomobject]@{ Index=$index+1; Name=$label; Type=$type; Status='failed'; Error=$message; DurationMs=[int]((Get-Date)-$stepStart).TotalMilliseconds })
            $failures.Add("${label}: $message")
            Write-Host "[FAIL] ${label}: $message" -ForegroundColor Red
            $mainWindow = Get-MainWindowInfo $script:clientProcess.Id
            if ($mainWindow) { Save-WindowScreenshot $mainWindow.Handle (Join-Path $OutputDir ('failure-{0:D2}.png' -f ($index + 1))) }
            break
        }
    }

    $currentStage = 'artifact-collection'
    $unexpected = Find-MatchingWindows $script:clientProcess.Id '.*' 'К сожалению, возникла непредвиденная ситуация|unexpected situation'
    if ($unexpected) { $failures.Add('The client contains an unexpected-situation dialog.') }

    $mainWindow = Get-MainWindowInfo $script:clientProcess.Id
    if ($mainWindow) { Save-WindowScreenshot $mainWindow.Handle (Join-Path $OutputDir 'final.png') }
    Save-UiDump (Join-Path $OutputDir 'ui-tree.json')
    Write-JsonFile @(Get-ClientWindows $script:clientProcess.Id) (Join-Path $OutputDir 'windows.json')

    $currentStage = 'event-log'
    if ($IncludeEventLog -and $InfoBasePath -and (Test-Path -LiteralPath (Join-Path $InfoBasePath '1Cv8Log'))) {
        $ibcmd = if ($V8Path) {
            $resolved = Resolve-V8Executable $V8Path 'Thick'
            Join-Path (Split-Path $resolved -Parent) 'ibcmd.exe'
        } else { Join-Path (Split-Path (Resolve-V8Executable '' 'Thick') -Parent) 'ibcmd.exe' }
        if (Test-Path -LiteralPath $ibcmd) {
            $eventFile = Join-Path $OutputDir 'eventlog.json'
            $fromArg = '--from=' + $startedAt.ToString('yyyy-MM-ddTHH:mm:ss')
            & $ibcmd eventlog export '--format=json' $fromArg ('--out=' + $eventFile) (Join-Path $InfoBasePath '1Cv8Log') | Out-Null
            if (Test-Path -LiteralPath $eventFile) {
                try {
                    $parsed = Get-Content -LiteralPath $eventFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    $events = if ($parsed.PSObject.Properties['events']) {
                        @($parsed.events)
                    } elseif ($parsed.PSObject.Properties['EventLog']) {
                        @($parsed.EventLog)
                    } else {
                        @($parsed)
                    }
                    $eventErrors = @($events | Where-Object { $_.Level -in @('Error','Warning') -or $_.Comment -match 'ошиб|exception' })
                    Write-JsonFile $eventErrors (Join-Path $OutputDir 'eventlog-errors.json') 10
                } catch {}
            }
        }
    }
    $currentStage = 'complete'
} catch {
    $failures.Add($_.Exception.Message)
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
} finally {
    $endedAt = Get-Date
    if ($script:clientProcess) {
        if ($IncludeTechLog -or $IncludeDumps) {
            try { Copy-ClientDiagnostics $script:clientProcess.Id $startedAt $OutputDir -TechLog:$IncludeTechLog -Dumps:$IncludeDumps } catch {}
        }
        try {
            $script:clientProcess.Refresh()
            $processSnapshot = [pscustomobject]@{
                Id = $script:clientProcess.Id
                HasExited = $script:clientProcess.HasExited
                Responding = if ($script:clientProcess.HasExited) { $null } else { $script:clientProcess.Responding }
                MainWindowHandle = if ($script:clientProcess.HasExited) { 0 } else { $script:clientProcess.MainWindowHandle.ToInt64() }
                MainWindowTitle = if ($script:clientProcess.HasExited) { '' } else { $script:clientProcess.MainWindowTitle }
                TotalProcessorSeconds = if ($script:clientProcess.HasExited) { $null } else { [math]::Round($script:clientProcess.TotalProcessorTime.TotalSeconds, 3) }
                WorkingSetBytes = if ($script:clientProcess.HasExited) { $null } else { $script:clientProcess.WorkingSet64 }
                PrivateMemoryBytes = if ($script:clientProcess.HasExited) { $null } else { $script:clientProcess.PrivateMemorySize64 }
            }
            Write-JsonFile $processSnapshot (Join-Path $OutputDir 'process.json') 5
            if (-not $script:clientProcess.HasExited) {
                $diagnosticWindows = @(Get-ClientWindows $script:clientProcess.Id)
                if (-not (Test-Path -LiteralPath (Join-Path $OutputDir 'windows.json'))) {
                    Write-JsonFile $diagnosticWindows (Join-Path $OutputDir 'windows.json') 5
                }
                if ($diagnosticWindows.Count -gt 0 -and -not (Test-Path -LiteralPath (Join-Path $OutputDir 'ui-tree.json'))) {
                    Save-UiDump (Join-Path $OutputDir 'ui-tree.json')
                    $diagnosticWindow = $diagnosticWindows | Sort-Object { $_.Width * $_.Height } -Descending | Select-Object -First 1
                    Save-WindowScreenshot $diagnosticWindow.Handle (Join-Path $OutputDir 'diagnostic-window.png')
                }
            }
        } catch {}
    }
    $result = [pscustomobject]@{
        Status = if ($failures.Count -eq 0) { 'passed' } else { 'failed' }
        StartedAt = $startedAt.ToString('o')
        EndedAt = $endedAt.ToString('o')
        DurationSeconds = [math]::Round(($endedAt - $startedAt).TotalSeconds, 3)
        StartupSeconds = if ($readyAt) { [math]::Round(($readyAt - $startedAt).TotalSeconds, 3) } else { $null }
        FinalStage = $currentStage
        ProcessId = if ($script:clientProcess) { $script:clientProcess.Id } else { $null }
        StartedByHarness = $startedByHarness
        Client = $Client
        URLProvided = [bool]$URL
        Diagnostics = [pscustomobject]@{
            EventLog = [bool]$IncludeEventLog
            TechLog = [bool]$IncludeTechLog
            Dumps = [bool]$IncludeDumps
        }
        Steps = @($steps)
        Failures = @($failures)
    }
    Write-JsonFile $result (Join-Path $OutputDir 'result.json') 10
    if ($startedByHarness -and -not $KeepClient -and $script:clientProcess -and -not $script:clientProcess.HasExited) {
        Stop-Process -Id $script:clientProcess.Id -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) { exit 1 }
Write-Host "[OK] Runtime test passed. Artifacts: $OutputDir" -ForegroundColor Green
