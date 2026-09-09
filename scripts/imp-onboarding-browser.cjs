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
    const message = 'Browser onboarding check: reply exactly IMP_BROWSER_OK.';
    await composer.fill(message);
    const sentRequest = page.waitForRequest(request => {
      if (request.method() !== 'POST' || new URL(request.url()).pathname !== '/api/v1/keepers/chat/stream') return false;
      const body = request.postDataJSON();
      return body?.name === 'imp' && body?.message === message;
    }, { timeout: 30000 });
    await page.getByRole('button', { name: '전송', exact: true }).first().click();
    const requestId = (await sentRequest).postDataJSON().request_id;
    if (typeof requestId !== 'string' || !requestId) throw new Error('Browser chat request has no operation identity');
    // Text can precede settlement. Wait for this operation's terminal SSE
    // projection so server cleanup cannot interrupt the browser turn.
    await page.waitForFunction(id => [...document.querySelectorAll('[data-chat-role="assistant"]')].some(node =>
      node.getAttribute('data-chat-stream-contract-request-id') === id &&
      ['RUN_FINISHED', 'RUN_ERROR'].includes(node.getAttribute('data-chat-stream-contract-event'))),
    requestId, { timeout: 120000 });
    const reply = page.locator('[data-chat-role="assistant"]').filter({ hasText: 'IMP_BROWSER_OK' }).last();
    if (await reply.getAttribute('data-chat-stream-contract-request-id') !== requestId ||
        await reply.getAttribute('data-chat-stream-contract-event') !== 'RUN_FINISHED' ||
        await reply.getAttribute('data-chat-stream-state') !== 'complete') {
      throw new Error('Browser chat did not finish successfully for the submitted operation');
    }
    const gateObservation = await page.locator('.v2-statchip.attn').evaluateAll(nodes =>
      nodes.map(node => ({ label: node.textContent, detail: node.getAttribute('title') })));
    fs.writeFileSync(path.join(outputDir, 'browser-gate-observation.json'),
      JSON.stringify(gateObservation, null, 2).split(token).join('[REDACTED]'));
    await reply.scrollIntoViewIfNeeded();
    await page.screenshot({ path: path.join(outputDir, 'imp-browser-chat.png'), fullPage: false });
    fs.writeFileSync(path.join(outputDir, 'browser-receipt.json'), JSON.stringify({
      url: page.url(), keeper: 'imp', interaction: 'typed and sent a real chat message',
      assistantReply: await reply.innerText(), requestId, terminalEvent: 'RUN_FINISHED',
      streamState: 'complete', fixtureModel: false,
    }, null, 2));
  } finally {
    await browser.close();
  }
})().catch(error => { process.stderr.write(error.message + '\n'); process.exitCode = 1; });
