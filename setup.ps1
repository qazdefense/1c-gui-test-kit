<#
Установка зависимостей веб-режима: Playwright + Chromium для навыка web-test.
Толстому/тонкому клиенту установка не нужна (PowerShell 5.1 + .NET UI Automation).
Повторный запуск безопасен.
#>
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw "Не найден Node.js 18+ (https://nodejs.org)." }
$major = [int]((& node --version) -replace '^v(\d+).*', '$1')
if ($major -lt 18) { throw "Нужен Node.js 18+, установлен $(& node --version)." }

$scripts = Join-Path $PSScriptRoot "skills\web-test\scripts"
Push-Location $scripts
try {
    & npm install --no-fund --no-audit
    if ($LASTEXITCODE -ne 0) { throw "npm install завершился с кодом $LASTEXITCODE" }
    & npx playwright install chromium
    if ($LASTEXITCODE -ne 0) { throw "playwright install завершился с кодом $LASTEXITCODE" }
} finally {
    Pop-Location
}

$bases = Join-Path $PSScriptRoot "bases"
if (-not (Get-ChildItem -Path $bases -Filter "*.psd1" | Where-Object { $_.Name -notlike "example-*" })) {
    Write-Host "Профилей баз пока нет: скопируйте bases\example-*.psd1 в bases\<ИмяБазы>.psd1." -ForegroundColor Yellow
}
Write-Host "Готово. Проверка: .\gui-test.ps1 -List" -ForegroundColor Green
