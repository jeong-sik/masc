// Browser interaction against the installed server, after the real tool checks.
// Credentials are read from the disposable workspace, never placed in the URL.
const fs = require('node:fs');
const path = require('node:path');
const [baseUrl, tokenFile, outputDir, playwrightModule, browserExecutable] = process.argv.slice(2);
const { chromium } = require(playwrightModule);
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: browserExecutable });
  try {
    const context = await browser.newContext({ viewport: { width: 1440, height: 1050 } });
    const token = fs.readFileSync(tokenFile, 'utf8').trim();
    await context.addInitScript(value => {
      sessionStorage.setItem('masc_bearer_token', value);
      sessionStorage.setItem('masc_bearer_token_meta', JSON.stringify({ source: 'manual' }));
    }, token);
    const page = await context.newPage();
    await page.goto(baseUrl + '/dashboard/?agent=local-admin#keepers?keeper=imp');
    await page.locator('[data-route-focused-keeper="imp"]').first().waitFor({ timeout: 45000 });
    const composer = page.locator('.composer-textarea').first();
    await composer.fill('Browser onboarding check: reply exactly IMP_BROWSER_OK.');
    await page.getByRole('button', { name: '전송', exact: true }).first().click();
    const reply = page.locator('[data-chat-role="assistant"]').filter({ hasText: 'IMP_BROWSER_OK' }).last();
    await reply.waitFor({ timeout: 120000 });
    await reply.scrollIntoViewIfNeeded();
    await page.screenshot({ path: path.join(outputDir, 'imp-browser-chat.png'), fullPage: false });
    fs.writeFileSync(path.join(outputDir, 'browser-receipt.json'), JSON.stringify({
      url: page.url(), keeper: 'imp', interaction: 'typed and sent a real chat message',
      assistantReply: await reply.innerText(), fixtureModel: false,
    }, null, 2));
  } finally {
    await browser.close();
  }
})().catch(error => { process.stderr.write(error.message + '\n'); process.exitCode = 1; });
