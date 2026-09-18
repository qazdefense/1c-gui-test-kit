// Хелперы для РАЗОВЫХ веб-сценариев (gui-test.ps1 -Web -ScriptPath).
// Для регрессионных тестов *.test.mjs - соседний 1c-helpers.mjs (с ctx).
//
// gui-test.ps1 подставляет этот файл перед каждым веб-сценарием, поэтому
// функции ниже доступны в сценарии без импорта. Построены поверх API web-test
// (getPage, getFormState, clickElement, filterList, readTable...) и закрывают
// особенности веб-клиента 1С (описаны в docs/gotchas.md).
//
// До этого файла gui-test.ps1 объявляет:
//   FIXTURES_DIR - абсолютный путь к <тесты>/_fixtures (прямые слэши)
//   SCENARIO_DIR - абсолютный путь к папке запущенного сценария

// 1С отдает в значениях НЕРАЗРЫВНЫЕ пробелы (U+00A0): на экране строки
// одинаковые, а ===/includes не срабатывают. Нормализовать обе стороны.
const norm = (s) => String(s ?? '').replace(/ /g, ' ').trim();

const fail = (msg) => { throw new Error(msg); };

const fixture = (name) => FIXTURES_DIR + '/' + name;

// Значение поля формы по имени (как его отдает getFormState()) или undefined.
async function getField(name) {
  const f = ((await getFormState()).fields || []).find(x => x.name === name);
  return f ? f.value : undefined;
}

// Поля HTML-документа (редактор Quill, предпросмотр, любой встроенный HTML) -
// отдельные iframe без url, селектор со страницы их не видит. Перебираем
// фреймы; фрейм мог пересоздаться, поэтому ошибки обращения игнорируются.
async function findFrame(probe) {
  const page = await getPage();
  for (const f of page.frames()) {
    try { if (await probe(f)) return f; } catch (e) { /* фрейм пересоздан */ }
  }
  return null;
}

const findFrameWithSelector = (selector) =>
  findFrame(async f => (await f.locator(selector).count()) > 0);

const findFrameWithText = (text) =>
  findFrame(async f => norm(await f.locator('body').innerText()).includes(norm(text)));

// Нажимает кнопку модального диалога платформы по точной подписи.
// Кнопки диалога НЕ попадают в getFormState().buttons, clickElement() до них
// не достает. Внимание: "OK" в диалоге выбора файла - ЛАТИНИЦЕЙ
// (U+004F U+004B), а соседняя "Отмена" - кириллицей.
async function clickDialogButton(caption) {
  const page = await getPage();
  const btn = page.getByText(caption, { exact: true }).filter({ visible: true }).last();
  if (!(await btn.count())) fail('Не найдена кнопка диалога "' + caption + '"');
  await btn.click();
}

// Присоединяет файл через команду формы с НачатьПомещениеФайла.
// Веб-клиент сначала показывает СВОЙ диалог "Выбор файла", а не диалог
// браузера, поэтому ожидание 'filechooser' виснет. Файл кладется в скрытый
// input#fileSelectButton этого диалога, затем диалог подтверждается.
async function uploadFile(command, filePath, { dialogTitle = /Выбор файла/i, okCaption = 'OK', settle = 3 } = {}) {
  await clickElement(command);
  await wait(2);
  const dlg = await getFormState();
  if (!dialogTitle.test(String(dlg.title || ''))) {
    fail('После "' + command + '" ожидался диалог выбора файла, а открыта форма: ' + dlg.title);
  }
  const page = await getPage();
  const input = page.locator('input[type=file]#fileSelectButton');
  if (!(await input.count())) fail('В диалоге выбора файла нет input[type=file]#fileSelectButton');
  await input.setInputFiles(filePath);
  await wait(settle);
  await clickDialogButton(okCaption);
  await wait(settle);
}

// Проверяет, что <img> во фрейме реально отрисован, а не просто есть в DOM:
// naturalWidth = 0 - "тег есть, файл не отдался".
async function assertImageRendered(frame, { index = 0 } = {}) {
  const imgs = frame.locator('img');
  const count = await imgs.count();
  if (count <= index) fail('Во фрейме нет картинки №' + index + ' (всего ' + count + ')');
  const r = await imgs.nth(index).evaluate(el => ({ w: el.naturalWidth, h: el.naturalHeight, src: String(el.src || '').slice(0, 80) }));
  if (!r.w || !r.h) fail('Картинка не отрисована (naturalWidth=0): ' + r.src);
  return r;
}

// Ищет строку динамического списка. Список отдает данные порциями:
// readTable() без отбора вернет ~20 строк, и свежий документ в конце списка
// "не найден", хотя виден на экране. Поэтому сначала отбор.
// Отбор остается включенным (им пользуется markForDeletion) - в конце
// сценария вызвать unfilterList().
async function findListRow(value, field) {
  await filterList(value, field ? { field } : undefined);
  await wait(2);
  const rows = (await readTable()).rows || [];
  return rows.find(r => (field ? norm(r[field]) : norm(Object.values(r).join(' '))).includes(norm(value))) || null;
}

// Помечает строку списка на удаление через "Ещё" -> "Пометить на удаление".
// Ctrl+Delete в веб-клиенте не работает (клавишу забирает браузер).
// Результат проверяется по признаку _deleted из readTable().
async function markForDeletion(value, field) {
  const row = await findListRow(value, field);
  if (!row) fail('Не найдена строка для пометки на удаление: ' + value);
  if (row._deleted) return;
  await clickElement(value);
  const more = await clickElement('Ещё');
  const item = (more.submenu || []).find(i => /пометить на удаление/i.test(i));
  if (!item) fail('В меню "Ещё" нет "Пометить на удаление": ' + JSON.stringify(more.submenu));
  await clickElement(item);
  await wait(2);
  const confirm = await getFormState();
  if (confirm.confirmation || /пометить|удал/i.test(String(confirm.title || ''))) {
    await clickElement('Да');
    await wait(2);
  }
  const after = await findListRow(value, field);
  if (after && !after._deleted) fail('Строка не помечена на удаление: ' + value);
}

// ----------------------------------------------------------------------------
