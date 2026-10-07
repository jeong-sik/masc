// Layout regression for the shipped page with long, valid participant names.
const assert = require('node:assert/strict');
const { readFileSync, mkdirSync, writeFileSync } = require('node:fs');
const { createRequire } = require('node:module');
const { resolve } = require('node:path');

async function main() {
  const [root, output, packagePath] = process.argv.slice(2).map(path => resolve(path));
  const { chromium } = createRequire(packagePath)('playwright');
  const source = readFileSync(resolve(root, 'lib/server/server_routes_http_routes_play_page.ml'), 'utf8');
  const part = name => source.match(new RegExp(`let page_${name} =\\s*\\{play\\|([\\s\\S]*?)\\|play\\}`))[1];
  const html = part('head') + 'layout-proof' + part('style') + '</main></body></html>';
  mkdirSync(output, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  const results = [];
  try {
    const page = await browser.newPage();
    await page.setContent(html);
    await page.evaluate(() => {
      const name = 'keeper_' + 'a'.repeat(57);
      document.getElementById('turn').textContent = name + ' 님 차례예요';
      document.getElementById('status').textContent = name + ' 연결을 다시 확인하고 있어요.';
      const option = document.createElement('option');
      option.textContent = name;
      document.getElementById('pass-to').append(option);
      const item = document.createElement('li');
      item.textContent = name + ' pass ' + name;
      document.getElementById('activity').append(item);
      document.getElementById('pad').hidden = false;
      for (const button of document.querySelectorAll('[data-button]')) button.textContent = '결정';
    });
    for (const width of [320, 390, 760, 1440]) {
      await page.setViewportSize({ width, height: 844 });
      results.push(await page.evaluate(() => ({
        viewport: innerWidth, document: document.documentElement.scrollWidth,
        overflow: [...document.querySelectorAll('main, main *')].filter(node => {
          const rect = node.getBoundingClientRect();
          return rect.width && (rect.right > innerWidth + 1 || rect.left < -1);
        }).map(node => node.id || node.tagName)
      })));
      await page.screenshot({ path: resolve(output, `viewport-${width}.png`), fullPage: true });
    }
    writeFileSync(resolve(output, 'viewport.json'), JSON.stringify(results, null, 2) + '\n');
    for (const result of results) {
      assert.equal(result.document, result.viewport, JSON.stringify(result));
      assert.deepEqual(result.overflow, [], JSON.stringify(result));
    }
    console.log(JSON.stringify({ result: 'PASS', results }));
  } finally { await browser.close(); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
