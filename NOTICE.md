# Сторонний код

Папка `skills/` содержит навыки **web-test** и **1c-client-test** из
[cc-1c-skills](https://github.com/Nikolay-Shirokov/cc-1c-skills)
(Nick Shirokov, лицензия MIT, текст — [skills/LICENSE-cc-1c-skills](skills/LICENSE-cc-1c-skills)),
в редакции форка [ivanarama/cc-1c-skills](https://github.com/ivanarama/cc-1c-skills),
коммит `62bb7f6` (2026-09-13). Навыки работают и сами по себе — по своим
`SKILL.md`; этот набор добавляет поверх них обертку, хелперы, примеры и
документацию.

## Изменения относительно upstream

Обе правки найдены на живых прогонах и помечены в коде комментарием
«Правка 1c-gui-test-kit».

1. **`skills/1c-client-test/scripts/client-test.ps1`, `Get-MainWindowInfo`** —
   главное окно клиента выбирается как самое большое видимое окно процесса
   (`MainWindowHandle` — только при равной площади). В оригинале .NET
   `Process.MainWindowHandle` на базе со всплывающим окном при старте
   указывал на это маленькое окно, и все скриншоты после готовности снимали
   его вместо главного окна.
2. **`skills/web-test/scripts/cli/exec-context.mjs`, `nextErrorShotPath`** —
   переменная окружения `WEB_TEST_ERROR_SHOT_DIR` задает папку для скриншота
   упавшего шага в режимах `run`/`exec` (раньше он всегда ложился в корень
   навыка, отдельно от остальных артефактов). Без переменной поведение
   прежнее.
