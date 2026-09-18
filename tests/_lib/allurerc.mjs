// Конфиг Allure 3 для gui-test.ps1 -Regress -Allure.
// singleFile: отчет - один index.html, открывается двойным кликом; обычный
// многофайловый отчет по file:// пустой (браузер блокирует загрузку данных).
// Категории падений Allure 3 читает только из конфига (categories.json в
// результатах - формат Allure 2, игнорируется), поэтому подгружаем
// <набор>/_allure/categories.json; путь к набору передает gui-test.ps1.
import { existsSync, readFileSync } from 'fs';
import { resolve } from 'path';

const suiteDir = process.env.GUI_TEST_SUITE_DIR;
const categoriesFile = suiteDir && resolve(suiteDir, '_allure', 'categories.json');
const categories = categoriesFile && existsSync(categoriesFile)
  ? JSON.parse(readFileSync(categoriesFile, 'utf8'))
  : undefined;

export default {
  name: 'GUI-тесты 1С',
  ...(categories ? { categories } : {}),
  plugins: {
    awesome: {
      options: {
        singleFile: true,
        reportLanguage: 'ru',
        groupBy: ['parentSuite', 'suite'],
      },
    },
  },
};
