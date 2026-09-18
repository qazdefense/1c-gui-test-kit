// Пример сквозного веб-сценария: документ с HTML-текстом и картинкой.
//
// Проверяется не "форма открылась", а результат работы пользователя:
// создание -> заголовок -> текст в HTML-редакторе -> присоединение картинки
// через диалог платформы -> предпросмотр содержит заголовок, текст и РЕАЛЬНО
// отрисованную картинку -> проведение -> документ виден в списке -> уборка.
//
// Написан под документ собственной конфигурации (уведомление с HTML-редактором
// Quill и предпросмотром). Для своей базы поменяйте имена в блоке ниже -
// сначала посмотрите их живьем: console.log(JSON.stringify(await getFormState())).
const DOC        = 'Документ.УведомлениеСотрудников';
const LIST_TITLE = /Уведомления сотрудников/i;
const TITLE_FIELD = 'Заголовок';
const IMAGE_FIELD = 'Обложка';
const UPLOAD_CMD  = 'Загрузить...';
const IMAGE       = fixture('post-cover.png');

const TITLE = 'GUI-тест: пост с картинкой ' + new Date().toISOString().slice(11, 19);
const BODY  = 'Проверка автотеста: этот пост создан через web-test (Playwright).';

// 1. Создание
await navigateLink(DOC);
await clickElement('Создать');
await fillFields({ [TITLE_FIELD]: TITLE });
await clickElement('Пост');
await clickElement('Описание рассылки');
await wait(2);

// 2. Текст в HTML-редакторе (отдельный iframe)
const editorFrame = await findFrameWithSelector('.ql-editor');
if (!editorFrame) fail('Не найден фрейм с редактором (.ql-editor)');
const editor = editorFrame.locator('.ql-editor').first();
await editor.click();
await editor.type(BODY, { delay: 10 });
console.log('OK: текст введен');

// 3. Картинка через диалог выбора файла платформы
if (await getField(IMAGE_FIELD)) fail('Поле картинки заполнено еще до загрузки');
await uploadFile(UPLOAD_CMD, IMAGE);
const attached = await getField(IMAGE_FIELD);
// В поле - наименование присоединенного файла БЕЗ расширения
if (!String(attached || '').includes('post-cover')) fail('Картинка не присоединилась, в поле: ' + attached);
console.log('OK: картинка присоединена ->', attached);

// 4. Предпросмотр: заголовок, текст, отрисованная картинка
await clickElement('Обновить предпросмотр');
await wait(3);
writeFileSync('post-form.png', await screenshot());   // рабочий каталог = папка артефактов
const preview = await findFrameWithText(TITLE);
if (!preview) fail('Предпросмотр с заголовком "' + TITLE + '" не найден');
if (!norm(await preview.locator('body').innerText()).includes(BODY.slice(0, 30))) fail('В предпросмотре нет текста');
const img = await assertImageRendered(preview);
console.log('OK: предпросмотр с текстом и картинкой', img.w + 'x' + img.h);

// 5. Проведение и проверка в списке
await clickElement('Провести и закрыть');
await wait(4);
const list = await getFormState();
if (!LIST_TITLE.test(String(list.title || ''))) fail('После проведения открыта не форма списка: ' + list.title);
if (!(await findListRow(TITLE, TITLE_FIELD))) fail('Проведенный документ не найден в списке: ' + TITLE);
console.log('OK: документ в списке');
writeFileSync('post-list.png', await screenshot());

// 6. Уборка за собой (обратимо: физически удаляет только "Удаление помеченных")
await markForDeletion(TITLE, TITLE_FIELD);
await unfilterList();
console.log('OK: тестовый документ помечен на удаление');
console.log('ИТОГ: сценарий пройден');
