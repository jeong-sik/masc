// Actual served HTML, actual APIs and actual TUI in an isolated workspace.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { createRequire } = require('node:module');
const { spawn } = require('node:child_process');
let stage = 'setup';

async function main() {
  const [origin, base, playerFile, adminFile, tui, output, packagePath] = process.argv.slice(2);
  const { chromium } = createRequire(path.resolve(packagePath))('playwright');
  const token = (await fs.readFile(playerFile, 'utf8')).trim();
  const browser = await chromium.launch({ headless:true });
  const errors = [];
  try {
    await fs.mkdir(output, { recursive:true });
    const page = await browser.newPage({ viewport:{ width:1200, height:900 } });
    page.on('pageerror', error => errors.push(error.message));
    stage = 'opening invitation';
    await page.goto(origin + '/play#' + token);
    await page.waitForFunction(() => document.getElementById('room-messages').textContent.includes('TUI reply'));
    await page.waitForFunction(() => {
      const canvas = document.getElementById('screen');
      return canvas.width > 1 && [...canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data]
        .some((value, index) => index % 4 !== 3 && value !== 0);
    });
    await page.locator('#chat-text').fill('Browser-to-TUI');
    await page.locator('#chat-send').click();
    await page.waitForFunction(() => document.getElementById('chat-text').value === '');
    stage = 'TUI and browser exchange';
    const child = spawn('python3', [path.join(__dirname, 'verify-play-room-tui.py'),
      path.resolve(tui), base, new URL(origin).port, adminFile, output], { stdio:['ignore', 'pipe', 'pipe'] });
    let childOutput = '';
    child.stdout.on('data', chunk => { childOutput += chunk; });
    child.stderr.on('data', chunk => { childOutput += chunk; });
    const exit = await new Promise(resolve => child.once('exit', resolve));
    assert.equal(exit, 0, childOutput.slice(-2500));
    await page.waitForFunction(() => document.getElementById('room-messages').textContent.includes('TUI-to-browser 한글'));
    assert.equal(await page.locator('#room-messages li').filter({ hasText:'TUI-to-browser 한글' }).count(), 1);
    await page.screenshot({ path:path.join(output, 'real-room-desktop.png'), fullPage:true });
    await page.locator('#machine-view').selectOption('msx');
    await page.waitForFunction(() => document.getElementById('turn').textContent.includes('MSX'));
    await page.waitForFunction(() => document.getElementById('status').textContent.includes('지금 켜진 게임이 없어요.'));
    await page.setViewportSize({ width:390, height:844 });
    await page.screenshot({ path:path.join(output, 'real-room-mobile.png'), fullPage:true });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), 390);
    stage = 'reload and disconnect';
    await page.reload();
    await page.waitForFunction(() => document.getElementById('room-messages').textContent.includes('TUI-to-browser 한글'));
    const departure = page.waitForResponse(response => response.url() === origin + '/api/v1/play/session' &&
      response.request().method() === 'POST');
    await page.locator('#leave').click();
    const departed = await departure;
    assert.deepEqual(departed.request().postDataJSON(), { connected:false });
    assert.equal(departed.status(), 200);
    assert.equal((await departed.json()).connected, false);
    await page.waitForFunction(() => sessionStorage.getItem('masc.play.invite') === null);
    assert.equal(await page.evaluate(() => sessionStorage.getItem('masc.play.room.draft')), null);
    assert.equal(await page.locator('#chat-text').isDisabled(), true);
    assert.deepEqual(errors, []);
    const checks = ['real served CSP page', 'real DOS emulator frame visible', 'browser sends and TUI reads', 'TUI sends and browser reads once',
      'MSX/DOS share history', 'mobile layout fits', 'reload retains conversation', 'atomic session departure',
      'disconnect clears credential and room draft', 'departed chat disabled'];
    await fs.writeFile(path.join(output, 'clients.json'), JSON.stringify({ pass:true, scope:'isolated actual server, TUI and original tiny DOS COM program; no fixture responses or production mutation', checks, errors }, null, 2));
    console.log(JSON.stringify({ pass:true, checks }));
  } finally { await browser.close(); }
}
// Playwright navigation errors can include the fragment credential.
main().catch(error => { console.error(error.name + ': client proof failed during ' + stage); process.exitCode = 1; });
