// The production event drain of lib/browser_ego_page_events.ml, unchanged,
// behind the rules declaration production puts before it. A test that runs a
// step script which drains a Page's events loads this text first.
const fs = require('node:fs');
const path = require('node:path');
const drain = fs.readFileSync(path.join(__dirname, '../lib/browser_ego_page_events.ml'), 'utf8')
  .split('let drain_source = {js|')[1].split('|js}')[0];
const productionRules = {requests: 200, pathBytes: 500, headerNames: 64, egoBuffer: 10000, redacted: 'REDACTED'};
module.exports = (rules = productionRules) => 'const mascNetworkRules = ' + JSON.stringify(rules) + ';\n' + drain;
