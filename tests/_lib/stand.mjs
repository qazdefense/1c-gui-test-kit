// Общая подготовка стенда для наборов <тесты>/<база>/ (_hooks.mjs реэкспортирует).
// prepare() не меняет данные базы, только проверяет, что публикация
// отвечает: без нее каждый тест упал бы по-своему, а так - одна понятная
// ошибка до запуска браузера. Нужна и при прямом вызове
// node run.mjs test ..., мимо gui-test.ps1.

export async function prepare({ log, config }) {
  const url = process.env.GUI_TEST_URL || config.url;
  if (!url) return;
  let res;
  try {
    res = await fetch(url, { signal: AbortSignal.timeout(15000) });
  } catch (e) {
    throw new Error(`Веб-публикация ${url} не отвечает: ${e.message}`);
  }
  if (!res.ok) throw new Error(`Веб-публикация ${url} ответила HTTP ${res.status}`);
  log('публикация отвечает:', url);
}
