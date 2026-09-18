# JSON-сценарий

Корень содержит массив `actions`. Общие поля: `type`, необязательные `name`, `timeoutSeconds` (целое число 0–3600, повторный поиск элемента или условия) и `screenshotAfter`. До запуска клиента весь сценарий проверяется целиком: типы действий, обязательные поля, регулярные выражения, перечисления и пути артефактов.

Поддерживаемые действия:

- `wait` — `milliseconds`.
- `screenshot` — `file`.
- `dumpUi` — сохранить дерево UI Automation.
- `assertWindow` / `assertNoWindow` — регулярное выражение `title` и необязательное регулярное выражение `containsElement` для семантического текста внутри верхнеуровневого окна процесса.
- `dismissWindow` — конкретный `title` либо `containsElement` обязателен; общий `.*` без семантического текста запрещён. `buttonName` по умолчанию равен `Закрыть`. Если подходящего окна нет, действие ничего не делает; найденное окно сначала сохраняется отдельным снимком, затем закрывается с polling-проверкой исчезновения до `timeoutSeconds`.
- `invoke` — найти UI Automation-элемент по `automationName` и вызвать `InvokePattern`.
- `select` — выбрать вкладку или другой элемент через `SelectionItemPattern`, с fallback на нативный клик.
- `clickElement` — кликнуть найденный по `automationName` элемент через доступный UI Automation-паттерн или нативную clickable point.
- `clickNearest` — выбрать ближайший к `anchorAutomationName` видимый элемент с именем `automationName`; поле `pattern` может ограничить кандидатов (`Invoke`, `Toggle`, `SelectionItem`). `optional: true` разрешает отсутствие стартовой панели при повторном attach-прогоне. Удобно для одноимённых кнопок вкладок 1С.
- `assertNearest` / `assertNoNearest` — проверить наличие или отсутствие видимого элемента рядом с `anchorAutomationName`. Кандидат ограничивается необязательными `automationName`, `controlType`, `pattern`, пространственным отношением `relation` (`below`, `above`, `left`, `right`) и расстоянием `maxDistance` в экранных пикселях; подходит для безымянных таблиц 1С.
- `toggle` — найти элемент по `automationName`, вызвать `TogglePattern`; необязательное ожидаемое `state`: `On`, `Off` или `Indeterminate`.
- `assertToggle` — проверить состояние `TogglePattern` без изменения элемента.
- `assertElement` / `assertNoElement` — наличие элемента UI Automation по `automationName`.
- `clickRelative` — fallback: `x` и `y` относительно левого верхнего угла основного окна либо окна `windowTitle`; значения от 0 до 1 считаются долями ширины/высоты.
- `sendKeys` — строка `keys` в синтаксисе `SendKeys`.

Сопоставление `automationName` игнорирует завершающее двоеточие, которое платформа 1С может автоматически добавлять к подписи поля. Если первым найден текст подписи, действия `toggle` и `assertToggle` выбирают ближайший элемент с `TogglePattern`.

Пример:

```json
{
  "actions": [
    {"type":"assertNoWindow", "title":"непредвиденная ситуация", "screenshotAfter":true},
    {"type":"toggle", "automationName":"Показывать остатки", "state":"On"},
    {"type":"assertElement", "automationName":"Остатки по текущей позиции"},
    {"type":"toggle", "automationName":"Показывать остатки", "state":"Off"},
    {"type":"screenshot", "file":"final.png"}
  ]
}
```

Если клиент 1С не публикует нужный элемент в UI Automation, сценарий должен завершиться ошибкой, а не автоматически переходить к произвольной экранной координате. Добавляй `clickRelative` отдельным явным действием и подтверждай результат следующей проверкой или снимком.

Имена файлов `screenshot` и `dumpUi`, а также снимки `screenshotAfter` обязаны оставаться внутри `OutputDir`; абсолютный путь наружу и `..` отклоняются до запуска клиента. По умолчанию результат пишется в `build/1c-client-test-<timestamp>`.

Офлайн-проверка сценария:

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/client-test.ps1" `
  -ScenarioPath ".\client-scenario.json" -ValidateScenarioOnly
```

Расширенная диагностика отключена по умолчанию. Включай независимо: `-IncludeEventLog` для журнала регистрации файловой базы, `-IncludeTechLog` для каталога журнала точного PID и `-IncludeDumps` для свежих дампов, содержащих PID тестируемого процесса в имени. Эти артефакты и снимки могут содержать прикладные данные и не должны автоматически попадать в Git.
