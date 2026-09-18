export const name = 'Открытие базы';
export const tags = ['smoke'];
export const timeout = 60000;

export default async function({ getFormState, getSections, assert, step, log }) {
  await step('База открылась без ошибок', async () => {
    assert.noErrors(await getFormState());
  });

  await step('Командный интерфейс прочитан', async () => {
    const s = await getSections();
    // Имена разделов доступны только в режиме панели "Картинка и текст"/"Текст";
    // при одних иконках список пустой - это не ошибка базы.
    log('разделов:', (s.sections || []).length, 'активный:', s.activeSection || '-');
  });
}
