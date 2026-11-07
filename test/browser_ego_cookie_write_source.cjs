// The production cookie write of lib/browser_ego_cookie_write.ml, unchanged:
// an async function of the Page, the step's arguments and the error reason.
const fs = require('node:fs');
const path = require('node:path');
module.exports = fs.readFileSync(path.join(__dirname, '../lib/browser_ego_cookie_write.ml'), 'utf8')
  .split('let script = {js|')[1].split('|js}')[0];
