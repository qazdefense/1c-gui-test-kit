<#
GUI-тестирование базы 1С по имени профиля - единая точка входа для человека
и агентов поверх навыков cc-1c-skills:

  толстый/тонкий клиент - 1c-client-test (Windows UI Automation, JSON-сценарий
      действий, снимки окон, дерево доступности);
  веб-клиент            - web-test (Playwright: разовые JS-сценарии и
      регрессионные наборы *.test.mjs с отчетом).

Все параметры подключения - в профиле базы: платформа (у баз бывают разные
версии, без явного -V8Path навык взял бы самую новую), путь или сервер\ref,
логин/пароль, URL публикации. Запуск сводится к "база + сценарий".

Один и тот же файл работает в двух раскладках (определяется сама):
  проект QazDefense - .1С\base-profiles\, .claude\skills\, .1С\gui-tests\,
                      артефакты в .1С\logs\gui-tests\;
  1c-gui-test-kit   - bases\, skills\, tests\, артефакты в artifacts\.
Пути переопределяются -BasesDir/-SkillsDir/-TestsDir или переменными
GUI_TEST_BASES_DIR/GUI_TEST_SKILLS_DIR/GUI_TEST_TESTS_DIR.

Использование (<тесты> - папка наборов: .1С\gui-tests или tests):
  # Регресс: набор <тесты>\<База>\ (*.test.mjs, режим test навыка web-test)
  gui-test.ps1 -Base Demo -Regress                              # весь набор, JSON-отчет
  gui-test.ps1 -Base Demo -Regress -Allure -OpenReport          # HTML-отчет Allure (один файл)
  gui-test.ps1 -Regress -TestPath <тесты>\Demo\02-документы     # часть набора; база - из пути
  gui-test.ps1 -Base Demo -Regress -Tags smoke -Bail
  gui-test.ps1 -Base Demo -Init                                 # заготовка набора для базы

  # Толстый клиент: все JSON-сценарии набора базы ("url" - в сценарии) или один
  gui-test.ps1 -Base Demo -Suite
  gui-test.ps1 -Base Demo -ScenarioPath x.json [-URL "e1cib/list/Справочник.Банки"] [-Client Thin]
  gui-test.ps1 -Base Demo -ScenarioPath x.json -ValidateScenarioOnly   # без запуска 1С

  # Разовый веб-сценарий / разведка (API: skills web-test\SKILL.md)
  gui-test.ps1 -Base Demo -Web -ScriptPath recon.js

  # Базы, режимы, сколько тестов в наборе
  gui-test.ps1 -List

Без -Base база берется из пути к тесту/сценарию, иначе - активная
(.1С\config.psd1, только в проекте).

Артефакты (скриншоты, result.json, отчеты) - в -OutputDir, по умолчанию
<артефакты>\<База>-<ггггММдд-ЧЧммсс>\. Код возврата: 0 - прошло, 1 - нет.
Снимки экрана содержат данные базы - в git не коммитить.

Требования: интерактивный разблокированный рабочий стол Windows (оба режима
показывают реальные окна). Для веба: Node.js 18+ и зависимости web-test
(npm install && npx playwright install chromium в skills\web-test\scripts).
#>
param(
    [string]$Base,
    [switch]$List,
    [string]$BasesDir,
    [string]$SkillsDir,
    [string]$TestsDir,

    # --- толстый/тонкий клиент (1c-client-test) ---
    [string]$ScenarioPath,
    [string]$URL,
    [ValidateSet("Thick", "Thin")]
    [string]$Client = "Thick",
    # 600, а не 60-180 по умолчанию у навыка: живой замер на «Бухгалтерии
    # для Казахстана 3.0» (файловая) - 149-192 секунды до готовности главного
    # окна, после принудительного закрытия клиента (пересборка кэша
    # конфигурации) - еще дольше; 240 не хватило. Опрос идет каждые 0.5 с,
    # так что для быстрых баз большой запас ничего не стоит.
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

    # --- регресс: набор <тесты>/<База>/ в режиме test навыка web-test ---
    [switch]$Regress,
    [string]$TestPath,          # подпапка или файл набора; по умолчанию весь набор
    [string]$Tags,              # через запятую, пересечение
    [string]$Grep,              # regex по имени теста
    [switch]$Bail,
    [int]$Retry = 0,
    [switch]$Record,            # видео каждого теста (нужен ffmpeg)
    [switch]$Allure,            # отчет Allure (HTML) вместо JSON
    [switch]$OpenReport,
    [string[]]$HookArgs,        # аргументы для prepare() в _hooks.mjs

    # --- набор JSON-сценариев толстого/тонкого клиента ---
    [switch]$Suite,

    # --- заготовка набора для базы (<тесты>/_lib/suite-template) ---
    [switch]$Init,

    [string]$OutputDir
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir = $PSScriptRoot
$IsProject = Test-Path -LiteralPath (Join-Path $ScriptDir "base-profiles")
if ($IsProject) {
    $RepoRoot = Split-Path -Parent $ScriptDir
    $defaults = @{ Bases = Join-Path $ScriptDir "base-profiles"; Skills = Join-Path $RepoRoot ".claude\skills"
                   Tests = Join-Path $ScriptDir "gui-tests"; Logs = Join-Path $ScriptDir "logs\gui-tests" }
} else {
    $RepoRoot = $ScriptDir
    $defaults = @{ Bases = Join-Path $ScriptDir "bases"; Skills = Join-Path $ScriptDir "skills"
                   Tests = Join-Path $ScriptDir "tests"; Logs = Join-Path $ScriptDir "artifacts" }
}
$ProfilesDir = if ($BasesDir) { $BasesDir } elseif ($env:GUI_TEST_BASES_DIR) { $env:GUI_TEST_BASES_DIR } else { $defaults.Bases }
$SkillsRoot  = if ($SkillsDir) { $SkillsDir } elseif ($env:GUI_TEST_SKILLS_DIR) { $env:GUI_TEST_SKILLS_DIR } else { $defaults.Skills }
$TestsRoot   = if ($TestsDir) { $TestsDir } elseif ($env:GUI_TEST_TESTS_DIR) { $env:GUI_TEST_TESTS_DIR } else { $defaults.Tests }
$ClientSkill = Join-Path $SkillsRoot "1c-client-test\scripts\client-test.ps1"
$WebRunner   = Join-Path $SkillsRoot "web-test\scripts\run.mjs"

# Профили баз; example-*.psd1 - образцы, не базы.
function Get-ProfileFiles {
    if (-not (Test-Path -LiteralPath $ProfilesDir)) { throw "Не найдена папка профилей баз: $ProfilesDir" }
    return @(Get-ChildItem -Path $ProfilesDir -Filter "*.psd1" | Where-Object { $_.Name -notlike "example-*" } | Sort-Object Name)
}

# Файлы набора без служебных папок (_lib, _allure, .*) - их пропускает и web-test.
# Фильтр по пути ОТНОСИТЕЛЬНО набора: в полном пути бывают папки с точкой (".1С").
function Get-SuiteFiles([string]$Dir, [string]$Filter) {
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $root = (Resolve-Path -LiteralPath $Dir).Path.TrimEnd('\')
    return @(Get-ChildItem -LiteralPath $root -Filter $Filter -Recurse |
        Where-Object { -not ($_.FullName.Substring($root.Length + 1).Split('\') | Where-Object { $_ -match '^[_.]' }) } |
        Sort-Object FullName)
}

function Get-SuiteStats([string]$Name) {
    $dir = Join-Path $TestsRoot $Name
    if (-not (Test-Path -LiteralPath $dir)) { return "-" }
    return "веб $(@(Get-SuiteFiles $dir '*.test.mjs').Count), клиент $(@(Get-SuiteFiles $dir '*.json').Count)"
}

function Assert-WebReady($BaseProfile, [string]$Name) {
    if (-not $BaseProfile.WebUrl) {
        $withWeb = @(Get-ProfileFiles | ForEach-Object {
            try { $q = Import-PowerShellDataFile -Path $_.FullName; if ($q.WebUrl) { [IO.Path]::GetFileNameWithoutExtension($_.Name) } } catch {}
        })
        throw "У базы '$Name' нет WebUrl в профиле — веб-клиент недоступен. С публикацией: $(if ($withWeb) { $withWeb -join ', ' } else { 'ни одной' }). Для этой базы используйте толстый клиент (без -Web)."
    }
    if (-not (Test-Path -LiteralPath $WebRunner)) { throw "Навык web-test не найден: $WebRunner" }
    if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $WebRunner -Parent) "node_modules"))) {
        throw "У навыка web-test не установлены зависимости: cd `"$(Split-Path $WebRunner -Parent)`" && npm install && npx playwright install chromium"
    }
    $webUrl = [string]$BaseProfile.WebUrl
    try {
        $probe = Invoke-WebRequest -Uri $webUrl -UseBasicParsing -TimeoutSec 15 -Method Get
        if ($probe.StatusCode -ne 200) { throw "HTTP $($probe.StatusCode)" }
    } catch {
        throw "Веб-публикация $webUrl не отвечает: $($_.Exception.Message). Проверьте IIS/Apache и сервер 1С."
    }
    return $webUrl
}

function Read-BaseProfile([string]$Name) {
    $path = Join-Path $ProfilesDir "$Name.psd1"
    if (-not (Test-Path -LiteralPath $path)) {
        $known = (Get-ProfileFiles | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) }) -join ", "
        throw "Профиль базы '$Name' не найден ($path). Есть: $known"
    }
    return Import-PowerShellDataFile -Path $path
}

if ($List) {
    Write-Host ("{0,-16} {1,-7} {2,-40} {3,-32} {4}" -f "База", "Тип", "Подключение", "Веб (для -Web)", "Набор тестов")
    foreach ($file in Get-ProfileFiles) {
        $id = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        try { $p = Import-PowerShellDataFile -Path $file.FullName } catch { Write-Host ("{0,-16} (ошибка чтения профиля)" -f $id); continue }
        $target = if ($p.ConnectionType -eq "Server") { "$($p.Server.Server)\$($p.Server.Ref)" } else { [string]$p.File.Path }
        $webCol = if ($p.WebUrl) { [string]$p.WebUrl } else { "-" }
        Write-Host ("{0,-16} {1,-7} {2,-40} {3,-32} {4}" -f $id, $p.ConnectionType, $target, $webCol, (Get-SuiteStats $id))
    }
    exit 0
}

# База не указана: берем из пути к тесту (<тесты>\<База>\...), иначе - активная
# база проекта (.1С\config.psd1 - копия одного из профилей, как в switch-base.ps1).
# Так задачи VS Code запускают "текущий файл" и "активную базу" без параметров.
if (-not $Base) {
    foreach ($p in @($TestPath, $ScenarioPath, $ScriptPath)) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $full = (Resolve-Path -LiteralPath $p).Path
        $rootFull = (Resolve-Path -LiteralPath $TestsRoot).Path.TrimEnd('\') + '\'
        if ($full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            $Base = $full.Substring($rootFull.Length).Split('\')[0]
            break
        }
    }
}
if (-not $Base) {
    $activeFile = Join-Path $ScriptDir "config.psd1"
    if (Test-Path -LiteralPath $activeFile) {
        $activeHash = (Get-FileHash -LiteralPath $activeFile -Algorithm SHA256).Hash
        $Base = Get-ProfileFiles |
            Where-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -eq $activeHash } |
            ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) } | Select-Object -First 1
    }
    if ($Base) { Write-Host "[gui-test] База не указана - активная: $Base" }
}
if (-not $Base) { throw "Укажите -Base <имя профиля> (список: gui-test.ps1 -List)." }
$prof = Read-BaseProfile $Base

if ($Init) {
    $suiteDir = Join-Path $TestsRoot $Base
    if (Test-Path -LiteralPath (Join-Path $suiteDir "webtest.config.mjs")) { throw "Набор уже есть: $suiteDir" }
    $template = Join-Path $TestsRoot "_lib\suite-template"
    New-Item -ItemType Directory -Force -Path $suiteDir | Out-Null
    Copy-Item -Path (Join-Path $template "*") -Destination $suiteDir -Recurse
    $cfg = Join-Path $suiteDir "webtest.config.mjs"
    [IO.File]::WriteAllText($cfg, ([IO.File]::ReadAllText($cfg, [Text.Encoding]::UTF8) -replace '__BASE__', $Base), [Text.UTF8Encoding]::new($false))
    Write-Host "[gui-test] Создан набор $suiteDir" -ForegroundColor Green
    if (-not $prof.WebUrl) { Write-Warning "У базы '$Base' нет WebUrl: веб-тесты не запустятся, пока база не опубликована. Для толстого клиента кладите JSON-сценарии в ту же папку и запускайте -Suite." }
    Write-Host "Проверка: gui-test.ps1 -Base `"$Base`" -Regress"
    exit 0
}

# Реестр для прямых вызовов навыков — держим свежим на каждом запуске.
$genProject = Join-Path $ScriptDir "gen-v8-project.ps1"
if (Test-Path -LiteralPath $genProject) {
    try { & $genProject -Quiet } catch { Write-Warning "gen-v8-project.ps1: $($_.Exception.Message)" }
}

if (-not $OutputDir) {
    $OutputDir = Join-Path $defaults.Logs ("{0}-{1}" -f $Base, (Get-Date -Format "yyyyMMdd-HHmmss"))
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# ============================ регресс (web-test test) ============================
if ($Regress) {
    $suiteDir = Join-Path $TestsRoot $Base
    $target = $suiteDir
    if ($TestPath) {
        $target = if (Test-Path -LiteralPath $TestPath) { (Resolve-Path -LiteralPath $TestPath).Path } else { Join-Path $suiteDir $TestPath }
        if (-not (Test-Path -LiteralPath $target)) { throw "Не найден путь внутри набора: $TestPath" }
        # Корень набора - ближайшая вверх папка с webtest.config.mjs (так же ищет web-test).
        $probeDir = if (Test-Path -LiteralPath $target -PathType Container) { $target } else { Split-Path $target -Parent }
        while ($probeDir -and -not (Test-Path -LiteralPath (Join-Path $probeDir "webtest.config.mjs"))) { $probeDir = Split-Path $probeDir -Parent }
        if ($probeDir) { $suiteDir = $probeDir }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $suiteDir "webtest.config.mjs"))) {
        throw "Нет набора регресса для базы '$Base': ожидается $suiteDir\webtest.config.mjs (заготовка: -Base `"$Base`" -Init)."
    }
    $url = Assert-WebReady $prof $Base

    # environment.properties для Allure: на чем получен результат.
    $gitRev = try { (& git -C $RepoRoot rev-parse --short HEAD 2>$null) } catch { "" }
    $envDir = Join-Path $suiteDir "_allure"
    New-Item -ItemType Directory -Force -Path $envDir | Out-Null
    # в .properties обратный слэш - экранирование, путь пишем прямыми
    $envLines = @("База=$Base", "URL=$url", "Платформа=$(([string]$prof.PlatformPath) -replace '\\', '/')", "Коммит=$gitRev", "Запуск=$(Get-Date -Format 'dd.MM.yyyy HH:mm')")
    [IO.File]::WriteAllText((Join-Path $envDir "environment.properties"), (($envLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

    $nodeArgs = @($WebRunner, "test", $target, "--url=$url")
    if ($Tags)  { $nodeArgs += "--tags=$Tags" }
    if ($Grep)  { $nodeArgs += "--grep=$Grep" }
    if ($Bail)  { $nodeArgs += "--bail" }
    if ($Retry) { $nodeArgs += "--retry=$Retry" }
    if ($Record) { $nodeArgs += "--record" }
    $resultsDir = Join-Path $OutputDir "allure-results"
    if ($Allure) { $nodeArgs += @("--format=allure", "--report-dir=$resultsDir") }
    else { $nodeArgs += @("--report=$(Join-Path $OutputDir 'report.json')", "--report-dir=$OutputDir") }
    if ($HookArgs) { $nodeArgs += "--"; $nodeArgs += $HookArgs }

    Write-Host "[gui-test] Регресс базы $Base ($url): $target"
    Write-Host "[gui-test] Артефакты: $OutputDir"
    $env:GUI_TEST_URL = $url
    $env:GUI_TEST_BASE = $Base
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        # Человекочитаемый отчет идет в stdout с последней строкой-сводкой;
        # сохраняем его рядом с машинным отчетом.
        $lines = New-Object System.Collections.Generic.List[string]
        & node @nodeArgs 2>&1 | ForEach-Object { $s = "$_"; $lines.Add($s); Write-Host $s }
        $code = $LASTEXITCODE
        [IO.File]::WriteAllLines((Join-Path $OutputDir "run-output.txt"), $lines, [Text.UTF8Encoding]::new($false))
    } finally {
        $ErrorActionPreference = $previousPreference
        Remove-Item Env:\GUI_TEST_URL, Env:\GUI_TEST_BASE -ErrorAction SilentlyContinue
    }

    if ($Allure) {
        $reportDir = Join-Path $OutputDir "allure-report"
        Write-Host "[gui-test] Сборка HTML-отчета Allure..."
        $ErrorActionPreference = "Continue"
        # allurerc.mjs: отчет одним файлом (открывается двойным кликом) и на русском.
        $env:GUI_TEST_SUITE_DIR = $suiteDir
        & npx --yes allure@3 generate $resultsDir -c (Join-Path $TestsRoot "_lib\allurerc.mjs") --name "GUI-тесты: $Base" -o $reportDir 2>&1 | Out-Null
        Remove-Item Env:\GUI_TEST_SUITE_DIR -ErrorAction SilentlyContinue
        $ErrorActionPreference = $previousPreference
        $index = Join-Path $reportDir "index.html"
        if (Test-Path -LiteralPath $index) {
            Write-Host "[gui-test] Отчет Allure: $index"
            if ($OpenReport) { Start-Process $index }
        } else {
            Write-Warning "HTML-отчет Allure не собрался; результаты в $resultsDir (npx allure@3 generate)."
        }
    }
    switch ($code) {
        0 { Write-Host "[OK] Регресс пройден. Артефакты: $OutputDir" -ForegroundColor Green }
        2 { Write-Host "[ERROR] Прогон прерван по общему лимиту времени. Артефакты: $OutputDir" -ForegroundColor Red }
        default { Write-Host "[FAIL] Есть упавшие тесты (код $code). Артефакты: $OutputDir" -ForegroundColor Red }
    }
    exit $code
}

# ===================== набор JSON-сценариев толстого клиента =====================
if ($Suite) {
    $suiteDir = Join-Path $TestsRoot $Base
    $files = @(Get-SuiteFiles $suiteDir "*.json")
    if (-not $files.Count) { throw "В $suiteDir нет JSON-сценариев толстого клиента." }
    $results = @()
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($suiteDir.Length + 1)
        $sub = Join-Path $OutputDir ([IO.Path]::GetFileNameWithoutExtension($f.Name))
        $callArgs = @{ Base = $Base; ScenarioPath = $f.FullName; Client = $Client; WaitReadySeconds = $WaitReadySeconds; OutputDir = $sub }
        if ($URL) { $callArgs.URL = $URL }
        Write-Host "=== $rel ===" -ForegroundColor Cyan
        $t0 = Get-Date
        # exit внутри скрипта, вызванного через &, завершает только его.
        $global:LASTEXITCODE = 1
        try { & $PSCommandPath @callArgs } catch { Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red; $global:LASTEXITCODE = 1 }
        $results += [pscustomobject]@{ Сценарий = $rel; Итог = $(if ($LASTEXITCODE -eq 0) { "OK" } else { "FAIL" }); Секунд = [int]((Get-Date) - $t0).TotalSeconds }
    }
    $results | Format-Table -AutoSize | Out-String | Write-Host
    [IO.File]::WriteAllText((Join-Path $OutputDir "suite.json"), ($results | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $failed = @($results | Where-Object { $_.Итог -ne "OK" }).Count
    Write-Host ("Пройдено {0} из {1}. Артефакты: {2}" -f ($results.Count - $failed), $results.Count, $OutputDir)
    if ($failed) { exit 1 } else { exit 0 }
}

# =============================== веб-клиент ===============================
if ($Web) {
    if (-not $ScriptPath) { throw "Для -Web укажите -ScriptPath <файл .js со сценарием web-test>." }
    if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Файл сценария не найден: $ScriptPath" }
    $url = Assert-WebReady $prof $Base

    $scriptFull = (Resolve-Path -LiteralPath $ScriptPath).Path
    # Сценарий + хелперы (_lib\1c-helpers.js) -> один файл: web-test выполняет
    # код как тело одной функции, импорта там нет. Номера строк в ошибках - по
    # этому файлу в папке артефактов. -NoHelpers - запуск сценария как есть.
    $runFile = $scriptFull
    $helpersFile = Join-Path $TestsRoot "_lib\1c-helpers.js"
    if (-not $NoHelpers -and (Test-Path -LiteralPath $helpersFile)) {
        $toJs = { param($v) "'" + (([string]$v) -replace '\\', '/' -replace "'", "\'") + "'" }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("const FIXTURES_DIR = $(& $toJs (Join-Path $TestsRoot '_fixtures'));")
        [void]$sb.AppendLine("const SCENARIO_DIR = $(& $toJs (Split-Path $scriptFull -Parent));")
        [void]$sb.AppendLine([IO.File]::ReadAllText($helpersFile, [Text.Encoding]::UTF8))
        [void]$sb.AppendLine("// ===== сценарий: $([IO.Path]::GetFileName($scriptFull)) =====")
        [void]$sb.Append([IO.File]::ReadAllText($scriptFull, [Text.Encoding]::UTF8))
        $runFile = Join-Path $OutputDir "_scenario.combined.js"
        [IO.File]::WriteAllText($runFile, $sb.ToString(), [Text.UTF8Encoding]::new($false))
    }
    Write-Host "[gui-test] База $Base, веб-клиент $url, сценарий $scriptFull"
    Write-Host "[gui-test] Артефакты: $OutputDir"
    # Скриншот упавшего шага навык по умолчанию кладёт в свой каталог
    # (см. exec-context.mjs, nextErrorShotPath) — уводим его к остальным
    # артефактам прогона, чтобы агенту не приходилось искать файл в двух местах.
    $env:WEB_TEST_ERROR_SHOT_DIR = $OutputDir
    Push-Location $OutputDir
    try {
        # run: открыть браузер -> выполнить -> закрыть; вывод — JSON {ok, output, error?, screenshot?}.
        # $ErrorActionPreference='Stop' + '2>&1' превращает ЛЮБУЮ строку в stderr
        # от node в терминирующую ошибку PowerShell (NativeCommandError) — сам
        # node при падении сценария пишет туда стек, и обёртка умирала раньше,
        # чем успевала разобрать JSON и сохранить артефакты (живой случай).
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $raw = & node $WebRunner run $url $runFile 2>&1 | Out-String
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
        $jsonStart = $raw.IndexOf("{")
        $parsed = ($raw.Substring($jsonStart) | ConvertFrom-Json)
        $ok = [bool]$parsed.ok
        [IO.File]::WriteAllText((Join-Path $OutputDir "result.json"), ($parsed | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        if ($parsed.output) { Write-Host "--- вывод сценария ---"; Write-Host $parsed.output }
        if (-not $ok) {
            Write-Host "[ERROR] $($parsed.error)" -ForegroundColor Red
            if ($parsed.screenshot) { Write-Host "Скриншот ошибки: $($parsed.screenshot) (в $OutputDir)" }
        }
    } catch {
        Write-Host $raw
        Write-Host "[ERROR] web-test не вернул разбираемый JSON (см. web-test-output.txt)" -ForegroundColor Red
    }
    if ($ok) { Write-Host "[OK] Веб-сценарий прошёл. Артефакты: $OutputDir" -ForegroundColor Green; exit 0 }
    exit 1
}

# ============================ толстый/тонкий клиент ============================
if (-not $ScenarioPath) { throw "Укажите -ScenarioPath <JSON-сценарий> (формат: .claude\skills\1c-client-test\references\scenario.md) или -Web -ScriptPath для веб-клиента." }
if (-not (Test-Path -LiteralPath $ScenarioPath)) { throw "Файл сценария не найден: $ScenarioPath" }
if (-not (Test-Path -LiteralPath $ClientSkill)) { throw "Навык 1c-client-test не найден: $ClientSkill" }

$scenarioFull = (Resolve-Path -LiteralPath $ScenarioPath).Path
# Стартовая навигационная ссылка может жить в самом сценарии ("url": "e1cib/list/...") -
# тогда наборы (-Suite) запускаются без -URL. Явный -URL важнее.
if (-not $URL) {
    try {
        $scenarioUrl = ([IO.File]::ReadAllText($scenarioFull, [Text.Encoding]::UTF8) | ConvertFrom-Json).url
        if ($scenarioUrl) { $URL = [string]$scenarioUrl }
    } catch { }
}
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
    # /DisableStartupDialogs подавляет в том числе диалог выбора пользователя,
    # поэтому он уместен ТОЛЬКО когда пользователь передан явно. На базе без
    # авторизации клиент с этим ключом молча падает с кодом 1 ещё до
    # появления окна — "1C client exited before readiness (code 1)", хотя без
    # ключа та же база стартует нормально (воспроизведено 2026-09-18).
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
