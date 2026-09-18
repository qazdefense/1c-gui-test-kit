// Пример регрессионного теста: документ с HTML-текстом и картинкой.
// Написан под документ собственной конфигурации (уведомление с редактором Quill
// и предпросмотром) - для своей базы поменяйте объект, имена полей и кнопок.
// Место в наборе: tests/<База>/02-<функция>/01-<сценарий>.test.mjs - путь
// импорта ниже рассчитан именно на него.
import {
  fixture, norm, stamp, getField, findFrameWithSelector, findFrameWithText,
  uploadFile, assertImageRendered, findListRow, markForDeletion,
} from '../../_lib/1c-helpers.mjs';

export const name = 'Уведомление-пост с картинкой: создание, предпросмотр, проведение';
export const tags = ['уведомления', 'присоединенные-файлы'];
export const timeout = 240000;

const TITLE = stamp('GUI-тест: пост с картинкой');
const BODY = 'Проверка автотеста: этот пост создан через web-test (Playwright).';

export default async function(ctx) {
  const { navigateLink, clickElement, fillFields, getFormState, wait, assert, step, log } = ctx;

  await step('Создать уведомление формата «Пост»', async () => {
    await navigateLink('Документ.УведомлениеСотрудников');
    await clickElement('Создать');
    await fillFields({ 'Заголовок': TITLE });
    await clickElement('Пост');
    await clickElement('Описание рассылки');
    await wait(2);
  });

  await step('Ввести текст в HTML-редакторе', async () => {
    const frame = await findFrameWithSelector(ctx, '.ql-editor');
    assert.ok(frame, 'Не найден фрейм с редактором (.ql-editor)');
    const editor = frame.locator('.ql-editor').first();
    await editor.click();
    await editor.type(BODY, { delay: 10 });
  });

  await step('Присоединить обложку через диалог выбора файла', async () => {
    assert.ok(!(await getField(ctx, 'Обложка')), 'Обложка заполнена еще до загрузки');
    await uploadFile(ctx, 'Загрузить...', fixture('post-cover.png'));
    const cover = await getField(ctx, 'Обложка');
    // в поле - наименование присоединенного файла без расширения
    assert.includes(String(cover || ''), 'post-cover', 'В поле "Обложка" не тот файл');
    log('обложка:', cover);
  });

  await step('Предпросмотр содержит заголовок, текст и картинку', async () => {
    await clickElement('Обновить предпросмотр');
    await wait(3);
    const preview = await findFrameWithText(ctx, TITLE);
    assert.ok(preview, 'Предпросмотр с заголовком не найден');
    assert.includes(norm(await preview.locator('body').innerText()), BODY.slice(0, 30), 'В предпросмотре нет текста поста');
    const img = await assertImageRendered(preview);
    log('картинка в предпросмотре:', img.w + 'x' + img.h);
  });

  await step('Провести и найти документ в списке', async () => {
    await clickElement('Провести и закрыть');
    await wait(4);
    assert.formTitle(await getFormState(), 'Уведомления сотрудников');
    const row = await findListRow(ctx, TITLE, 'Заголовок');
    assert.ok(row, 'Проведенный документ не найден в списке: ' + TITLE);
  });

  await step('Убрать за собой: пометить документ на удаление', async () => {
    await markForDeletion(ctx, TITLE, 'Заголовок');
    await ctx.unfilterList();
    cleaned = true;
  });
}

// Запасная уборка, если тест упал после записи документа. У teardown
// жесткий лимит 15 с, поэтому основная уборка - последним шагом теста.
let cleaned = false;
export async function teardown(ctx) {
  if (cleaned) return;
  try {
    await ctx.navigateLink('Документ.УведомлениеСотрудников');
    if (await findListRow(ctx, TITLE, 'Заголовок')) await markForDeletion(ctx, TITLE, 'Заголовок');
  } finally {
    try { await ctx.unfilterList(); } catch (e) { /* отбора могло не быть */ }
  }
}
