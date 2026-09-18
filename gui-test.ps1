<#
Единая точка входа GUI-тестов 1С по имени профиля базы (bases\<Имя>.psd1)
поверх навыков cc-1c-skills:

  толстый/тонкий клиент - skills\1c-client-test (Windows UI Automation,
      JSON-сценарий действий, снимки окон, дерево доступности);
  веб-клиент            - skills\web-test (Playwright, JS-сценарий,
      getFormState/navigateLink/readTable/fillFields/clickElement...).

Профиль базы хранит платформу, путь/сервер ИБ, логин/пароль и URL
веб-публикации, поэтому в сценариях этих данных нет, а запуск сводится к
"база + сценарий". Формат профиля - bases\example-*.psd1.

Использование:
  .\gui-test.ps1 -List                                            # базы и доступные режимы

  # веб-клиент (нужен WebUrl в профиле)
  .\gui-test.ps1 -Base Demo -Web -ScriptPath scenarios\examples\web\post-with-image.js

  # толстый/тонкий клиент
  .\gui-test.ps1 -Base Demo -ScenarioPath scenarios\examples\thick\catalog-list-smoke.json -URL "e1cib/list/Справочник.Банки"
  .\gui-test.ps1 -Base Demo -ScenarioPath ... -ValidateScenarioOnly   # проверка сценария без запуска 1С

  # набор: все *.js (с -Web) или *.json из папки, сводка и общий код возврата
  .\gui-test.ps1 -Base Demo -Web -Suite scenarios\Demo

Артефакты (скриншоты, result.json, дерево UI, вывод сценария) - в -OutputDir,
по умолчанию artifacts\<База>-<ггггММдд-ЧЧммсс>\. Снимки экрана содержат
данные базы - папка artifacts в .gitignore.
Код возврата: 0 - сценарий (все сценарии набора) прошел, 1 - нет.

Требования: интерактивный разблокированный рабочий стол Windows (оба режима
показывают реальные окна). Для -Web: Node.js 18+ и .\setup.ps1.
#>
param(
    [string]$Base,
    [switch]$List,
    [string]$BasesDir,
    [string]$SkillsDir,

    # --- толстый/тонкий клиент (1c-client-test) ---
    [string]$ScenarioPath,
    [string]$URL,
    [ValidateSet("Thick", "Thin")]
    [string]$Client = "Thick",
    # Первый старт толстого клиента на большой конфигурации - 150-190 секунд
    # (замер на "Бухгалтерии для Казахстана 3.0"); значения навыка по
    # умолчанию (60-180) срабатывают ложно. Опрос идет каждые 0.5 с, так что
    # для быстрых баз большой запас ничего не стоит.
    [int]$WaitReadySeconds = 600,
    [switch]$ValidateScenarioOnly,
    [switch]$KeepClient,
    [switch]$IncludeEventLog,
    [switch]$IncludeTechLog,
    [switch]$IncludeDumps,

    # --- веб-клиент (web-test) ---
    [switch]$Web,
    [string]$ScriptPath,
    [switch]$NoHelpers,

    # --- набор сценариев ---
    [string]$Suite,

    [string]$OutputDir
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$KitRoot = $PSScriptRoot
if (-not $BasesDir)  { $BasesDir  = if ($env:GUI_TEST_BASES_DIR) { $env:GUI_TEST_BASES_DIR } else { Join-Path $KitRoot "bases" } }
if (-not $SkillsDir) { $SkillsDir = if ($env:GUI_TEST_SKILLS_DIR) { $env:GUI_TEST_SKILLS_DIR } else { Join-Path $KitRoot "skills" } }
$ClientSkill = Join-Path $SkillsDir "1c-client-test\scripts\client-test.ps1"
$WebRunner   = Join-Path $SkillsDir "web-test\scripts\run.mjs"
$HelpersFile = Join-Path $KitRoot "lib\1c-helpers.js"
$FixturesDir = Join-Path $KitRoot "scenarios\_fixtures"

function Get-ProfileFiles {
    if (-not (Test-Path -LiteralPath $BasesDir)) { throw "Не найдена папка профилей баз: $BasesDir" }
    return Get-ChildItem -Path $BasesDir -Filter "*.psd1" | Where-Object { $_.Name -notlike "example-*" } | Sort-Object Name
}

function Read-BaseProfile([string]$Name) {
    $path = Join-Path $BasesDir "$Name.psd1"
    if (-not (Test-Path -LiteralPath $path)) {
        $known = (Get-ProfileFiles | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) }) -join ", "
        throw "Профиль базы '$Name' не найден ($path). Есть: $(if ($known) { $known } else { 'ни одного - скопируйте bases\example-*.psd1' })"
    }
    return Import-PowerShellDataFile -Path $path
}

function ConvertTo-JsString([string]$Value) {
    return "'" + ($Value -replace '\\', '/' -replace "'", "\'") + "'"
}

if ($List) {
    Write-Host ("{0,-16} {1,-7} {2,-40} {3}" -f "База", "Тип", "Подключение", "Веб (для -Web)")
    foreach ($file in Get-ProfileFiles) {
        $id = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        try { $p = Import-PowerShellDataFile -Path $file.FullName } catch { Write-Host ("{0,-16} (ошибка чтения профиля)" -f $id); continue }
        $target = if ($p.ConnectionType -eq "Server") { "$($p.Server.Server)\$($p.Server.Ref)" } else { [string]$p.File.Path }
        $webCol = if ($p.WebUrl) { [string]$p.WebUrl } else { "-" }
        Write-Host ("{0,-16} {1,-7} {2,-40} {3}" -f $id, $p.ConnectionType, $target, $webCol)
    }
    exit 0
}

if (-not $Base) { throw "Укажите -Base <имя профиля> (список: .\gui-test.ps1 -List)." }
$prof = Read-BaseProfile $Base
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

# =============================== набор ===============================
if ($Suite) {
    if (-not (Test-Path -LiteralPath $Suite)) { throw "Папка набора не найдена: $Suite" }
    $filter = if ($Web) { "*.js" } else { "*.json" }
    $files = @(Get-ChildItem -LiteralPath $Suite -Filter $filter -Recurse | Sort-Object FullName)
    if (-not $files.Count) { throw "В $Suite нет сценариев $filter" }
    if (-not $OutputDir) { $OutputDir = Join-Path $KitRoot ("artifacts\{0}-suite-{1}" -f $Base, $stamp) }
    $results = @()
    foreach ($f in $files) {
        $name = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $sub = Join-Path $OutputDir $name
        $callArgs = @{ Base = $Base; BasesDir = $BasesDir; SkillsDir = $SkillsDir; OutputDir = $sub }
        if ($Web) { $callArgs.Web = $true; $callArgs.ScriptPath = $f.FullName; if ($NoHelpers) { $callArgs.NoHelpers = $true } }
        else {
            $callArgs.ScenarioPath = $f.FullName; $callArgs.Client = $Client; $callArgs.WaitReadySeconds = $WaitReadySeconds
            if ($URL) { $callArgs.URL = $URL }
        }
        Write-Host "=== $($f.Name) ===" -ForegroundColor Cyan
        $t0 = Get-Date
        # exit внутри вызванного через & скрипта завершает только его и
        # выставляет $LASTEXITCODE; throw (ошибка окружения) - ловим сами.
        $global:LASTEXITCODE = 1
        try { & $PSCommandPath @callArgs } catch { Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red; $global:LASTEXITCODE = 1 }
        $results += [pscustomobject]@{ Scenario = $f.Name; Ok = ($LASTEXITCODE -eq 0); Seconds = [int]((Get-Date) - $t0).TotalSeconds; Artifacts = $sub }
    }
    Write-Host ""
    $results | Format-Table Scenario, @{ n = "Итог"; e = { if ($_.Ok) { "OK" } else { "FAIL" } } }, Seconds -AutoSize | Out-String | Write-Host
    $results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDir "suite.json") -Encoding UTF8
    $failed = @($results | Where-Object { -not $_.Ok }).Count
    Write-Host ("Пройдено {0} из {1}. Артефакты: {2}" -f ($results.Count - $failed), $results.Count, $OutputDir)
    if ($failed) { exit 1 } else { exit 0 }
}

if (-not $OutputDir) { $OutputDir = Join-Path $KitRoot ("artifacts\{0}-{1}" -f $Base, $stamp) }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# =============================== веб-клиент ===============================
if ($Web) {
    if (-not $ScriptPath) { throw "Для -Web укажите -ScriptPath <файл .js со сценарием web-test>." }
    if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Файл сценария не найден: $ScriptPath" }
    if (-not $prof.WebUrl) { throw "У базы '$Base' нет WebUrl в профиле - веб-клиент недоступен, используйте толстый клиент (без -Web)." }
    if (-not (Test-Path -LiteralPath $WebRunner)) { throw "Навык web-test не найден: $WebRunner" }
    if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $WebRunner -Parent) "node_modules"))) {
        throw "Не установлены зависимости web-test - запустите .\setup.ps1"
    }
    $url = [string]$prof.WebUrl
    try {
        $probe = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -Method Get
        if ($probe.StatusCode -ne 200) { throw "HTTP $($probe.StatusCode)" }
    } catch {
        throw "Веб-публикация $url не отвечает: $($_.Exception.Message). Проверьте веб-сервер и сервер 1С."
    }

    # Сценарий + хелперы -> один файл: web-test выполняет код как тело одной
    # функции, импорта там нет. Номера строк в ошибках - по этому файлу.
    $scriptFull = (Resolve-Path -LiteralPath $ScriptPath).Path
    $combined = Join-Path $OutputDir "_scenario.combined.js"
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("const FIXTURES_DIR = $(ConvertTo-JsString $FixturesDir);")
    [void]$sb.AppendLine("const SCENARIO_DIR = $(ConvertTo-JsString (Split-Path $scriptFull -Parent));")
    if (-not $NoHelpers) { [void]$sb.AppendLine([IO.File]::ReadAllText($HelpersFile, [Text.Encoding]::UTF8)) }
    [void]$sb.AppendLine("// ===== сценарий: $([IO.Path]::GetFileName($scriptFull)) =====")
    [void]$sb.Append([IO.File]::ReadAllText($scriptFull, [Text.Encoding]::UTF8))
    [IO.File]::WriteAllText($combined, $sb.ToString(), [Text.UTF8Encoding]::new($false))

    Write-Host "[gui-test] База $Base, веб-клиент $url, сценарий $scriptFull"
    Write-Host "[gui-test] Артефакты: $OutputDir"
    # Скриншот упавшего шага навык по умолчанию кладет в свой каталог -
    # уводим его к остальным артефактам прогона.
    $env:WEB_TEST_ERROR_SHOT_DIR = $OutputDir
    Push-Location $OutputDir
    try {
        # $ErrorActionPreference='Stop' + '2>&1' превращает любую строку stderr
        # от node в терминирующую ошибку PowerShell, и обертка умирала раньше,
        # чем успевала разобрать JSON-результат.
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $raw = & node $WebRunner run $url $combined 2>&1 | Out-String
        } finally {
            $ErrorActionPreference = $previousPreference
        }
    } finally {
        Pop-Location
        Remove-Item Env:\WEB_TEST_ERROR_SHOT_DIR -ErrorAction SilentlyContinue
    }
    [IO.File]::WriteAllText((Join-Path $OutputDir "web-test-output.txt"), $raw, [Text.UTF8Encoding]::new($false))
    $ok = $false
    try {
        $parsed = ($raw.Substring($raw.IndexOf("{")) | ConvertFrom-Json)
        $ok = [bool]$parsed.ok
        [IO.File]::WriteAllText((Join-Path $OutputDir "result.json"), ($parsed | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        if ($parsed.output) { Write-Host "--- вывод сценария ---"; Write-Host $parsed.output }
        if (-not $ok) {
            Write-Host "[ERROR] $($parsed.error)" -ForegroundColor Red
            if ($parsed.screenshot) { Write-Host "Скриншот ошибки: $($parsed.screenshot)" }
        }
    } catch {
        Write-Host $raw
        Write-Host "[ERROR] web-test не вернул разбираемый JSON (см. web-test-output.txt)" -ForegroundColor Red
    }
    if ($ok) { Write-Host "[OK] Веб-сценарий прошел. Артефакты: $OutputDir" -ForegroundColor Green; exit 0 }
    exit 1
}

# ============================ толстый/тонкий клиент ============================
if (-not $ScenarioPath) { throw "Укажите -ScenarioPath <JSON-сценарий> (формат: skills\1c-client-test\references\scenario.md) или -Web -ScriptPath для веб-клиента." }
if (-not (Test-Path -LiteralPath $ScenarioPath)) { throw "Файл сценария не найден: $ScenarioPath" }
if (-not (Test-Path -LiteralPath $ClientSkill)) { throw "Навык 1c-client-test не найден: $ClientSkill" }

$scenarioFull = (Resolve-Path -LiteralPath $ScenarioPath).Path
$cmdArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ClientSkill,
             "-ScenarioPath", $scenarioFull, "-OutputDir", $OutputDir)

if ($ValidateScenarioOnly) {
    $cmdArgs += "-ValidateScenarioOnly"
    Write-Host "[gui-test] Проверка сценария без запуска 1С: $scenarioFull"
    & powershell.exe @cmdArgs
    exit $LASTEXITCODE
}

if (-not $prof.PlatformPath -or -not (Test-Path -LiteralPath $prof.PlatformPath)) {
    throw "В профиле '$Base' не найден PlatformPath (1cv8.exe): $($prof.PlatformPath)"
}
$cmdArgs += @("-V8Path", [string]$prof.PlatformPath, "-Client", $Client,
              "-WaitReadySeconds", $WaitReadySeconds)

switch ($prof.ConnectionType) {
    "File" {
        if (-not (Test-Path -LiteralPath $prof.File.Path)) { throw "Не найдена папка файловой ИБ: $($prof.File.Path)" }
        $cmdArgs += @("-InfoBasePath", [string]$prof.File.Path)
        $target = [string]$prof.File.Path
    }
    "Server" {
        if (-not $prof.Server.Server -or -not $prof.Server.Ref) { throw "В профиле '$Base' для Server не заполнены Server.Server/Server.Ref" }
        $cmdArgs += @("-InfoBaseServer", [string]$prof.Server.Server, "-InfoBaseRef", [string]$prof.Server.Ref)
        $target = "$($prof.Server.Server)\$($prof.Server.Ref)"
    }
    default { throw "Неизвестный ConnectionType в профиле '$Base': $($prof.ConnectionType)" }
}
if ($prof.Auth -and $prof.Auth.User) {
    $cmdArgs += @("-UserName", [string]$prof.Auth.User)
    if ($prof.Auth.Password) { $cmdArgs += @("-Password", [string]$prof.Auth.Password) }
    # /DisableStartupDialogs подавляет и диалог выбора пользователя, поэтому
    # уместен только при явном логине: на базе без авторизации клиент с этим
    # ключом молча завершается с кодом 1 еще до появления окна.
    $cmdArgs += "-DisableStartupDialogs"
}
if ($URL) { $cmdArgs += @("-URL", $URL) }
if ($KeepClient) { $cmdArgs += "-KeepClient" }
if ($IncludeEventLog) { $cmdArgs += "-IncludeEventLog" }
if ($IncludeTechLog) { $cmdArgs += "-IncludeTechLog" }
if ($IncludeDumps) { $cmdArgs += "-IncludeDumps" }

Write-Host "[gui-test] База $Base ($($prof.ConnectionType): $target), клиент $Client, платформа $($prof.PlatformPath)"
Write-Host "[gui-test] Сценарий: $scenarioFull"
Write-Host "[gui-test] Артефакты: $OutputDir"
& powershell.exe @cmdArgs
exit $LASTEXITCODE
