// Набор регрессионных тестов базы __BASE__.
// URL не задается: gui-test.ps1 передает --url из профиля базы __BASE__
// (WebUrl), чтобы адрес жил в одном месте.
export default {
  timeout: 120000,
  retries: 0,
  screenshot: 'on-failure',
  severity: {
    critical: ['smoke'],
  },
  defaultSeverity: 'normal',
};
