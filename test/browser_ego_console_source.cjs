// The production console read of lib/browser_ego_console.ml, unchanged,
// behind a rules declaration like the one production puts before it. It
// needs the event drain of browser_ego_page_events_source.cjs before it.
const fs = require('node:fs');
const path = require('node:path');
const read = fs.readFileSync(path.join(__dirname, '../lib/browser_ego_console.ml'), 'utf8')
  .split('let read_source = {js|')[1].split('|js}')[0];
module.exports = rules => 'const mascConsoleRules = ' + JSON.stringify(rules) + ';\n' + read;
