// Хелперы для регрессионных тестов web-test (*.test.mjs).
// Каждая функция принимает ctx теста первым аргументом: в режиме test API
// браузера живет в ctx, а не в глобальной области, как в run/exec.
// Грабли веб-клиента, которые закрывают эти функции, - docs/gotchas.md в
// 1c-gui-test-kit (в проекте - база знаний, раздел «Тестирование»).

import { fileURLToPath } from 'url';
import { dirname, resolve } from 'path';

const LIB_DIR = dirname(fileURLToPath(import.meta.url));

export const FIXTURES_DIR = resolve(LIB_DIR, '..', '_fixtures');

export const fixture = (name) => resolve(FIXTURES_DIR, name);

// 1С отдает в значениях неразрывные пробелы (U+00A0).
export const norm = (s) => String(s ?? '').replace(/ /g, ' ').trim();

// Метка для уникальных тестовых данных: прогоны не мешают друг другу,
// строку можно найти отбором и убрать за собой.
export const stamp = (prefix = 'GUI-тест') => prefix + ' ' + new Date().toISOString().slice(11, 19);

export async function getField(ctx, name) {
  const f = ((await ctx.getFormState()).fields || []).find(x => x.name === name);
  return f ? f.value : undefined;
}

// Поля HTML-документа - отдельные iframe без url.
export async function findFrame(ctx, probe) {
  const page = await ctx.getPage();
  for (const f of page.frames()) {
    try { if (await probe(f)) return f; } catch (e) { /* фрейм пересоздан */ }
  }
  return null;
}

export const findFrameWithSelector = (ctx, selector) =>
  findFrame(ctx, async f => (await f.locator(selector).count()) > 0);

export const findFrameWithText = (ctx, text) =>
  findFrame(ctx, async f => norm(await f.locator('body').innerText()).includes(norm(text)));

// Кнопки модального диалога платформы не попадают в getFormState().buttons.
// "OK" в диалоге выбора файла - латиницей.
export async function clickDialogButton(ctx, caption) {
  const page = await ctx.getPage();
  const btn = page.getByText(caption, { exact: true }).filter({ visible: true }).last();
  if (!(await btn.count())) throw new Error('Не найдена кнопка диалога "' + caption + '"');
  await btn.click();
}

// Присоединение файла через команду с НачатьПомещениеФайла: сначала свой
// диалог 1С "Выбор файла", файл кладется в его скрытый input#fileSelectButton.
export async function uploadFile(ctx, command, filePath, { dialogTitle = /Выбор файла/i, okCaption = 'OK', settle = 3 } = {}) {
  await ctx.clickElement(command);
  await ctx.wait(2);
  const dlg = await ctx.getFormState();
  if (!dialogTitle.test(String(dlg.title || ''))) {
    throw new Error('После "' + command + '" ожидался диалог выбора файла, а открыта форма: ' + dlg.title);
  }
  const page = await ctx.getPage();
  const input = page.locator('input[type=file]#fileSelectButton');
  if (!(await input.count())) throw new Error('В диалоге выбора файла нет input[type=file]#fileSelectButton');
  await input.setInputFiles(filePath);
  await ctx.wait(settle);
  await clickDialogButton(ctx, okCaption);
  await ctx.wait(settle);
}

// naturalWidth = 0 - тег есть, файл не отдался.
export async function assertImageRendered(frame, { index = 0 } = {}) {
  const imgs = frame.locator('img');
  const count = await imgs.count();
  if (count <= index) throw new Error('Во фрейме нет картинки №' + index + ' (всего ' + count + ')');
  const r = await imgs.nth(index).evaluate(el => ({ w: el.naturalWidth, h: el.naturalHeight, src: String(el.src || '').slice(0, 80) }));
  if (!r.w || !r.h) throw new Error('Картинка не отрисована (naturalWidth=0): ' + r.src);
  return r;
}

// Динамический список отдает ~20 строк без отбора - ищем только через отбор.
// Отбор остается включенным, снимать - ctx.unfilterList().
export async function findListRow(ctx, value, field) {
  await ctx.filterList(value, field ? { field } : undefined);
  await ctx.wait(2);
  const rows = (await ctx.readTable()).rows || [];
  return rows.find(r => (field ? norm(r[field]) : norm(Object.values(r).join(' '))).includes(norm(value))) || null;
}

// Пометка на удаление через "Ещё" (Ctrl+Delete в браузере не работает).
// _deleted отсутствует = "неизвестно", поэтому проверка строго === true.
export async function markForDeletion(ctx, value, field) {
  const row = await findListRow(ctx, value, field);
  if (!row) throw new Error('Не найдена строка для пометки на удаление: ' + value);
  if (row._deleted === true) return;
  await ctx.clickElement(value);
  const more = await ctx.clickElement('Ещё');
  const item = (more.submenu || []).find(i => /пометить на удаление/i.test(i));
  if (!item) throw new Error('В меню "Ещё" нет "Пометить на удаление": ' + JSON.stringify(more.submenu));
  await ctx.clickElement(item);
  await ctx.wait(2);
  const confirm = await ctx.getFormState();
  if (confirm.confirmation || /пометить|удал/i.test(String(confirm.title || ''))) {
    await ctx.clickElement('Да');
    await ctx.wait(2);
  }
  const after = await findListRow(ctx, value, field);
  // строка пропала из списка - тоже результат: список скрывает помеченные
  if (after && after._deleted !== true) throw new Error('Строка не помечена на удаление: ' + value);
}
