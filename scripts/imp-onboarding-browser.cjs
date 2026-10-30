// Browser interaction against the installed server, after the real tool checks.
// Credentials are read from the disposable workspace, never placed in the URL.
const fs = require('node:fs');
const path = require('node:path');
async function waitForDurableOperation(page, operationUrl, token, requestId, { timeoutMs = 120000, now = Date.now } = {}) {
  const deadline = now() + timeoutMs;
  let observed = false;
  while (now() < deadline) {
    const response = await page.request.get(operationUrl, {
      headers: { Authorization: 'Bearer ' + token }, timeout: Math.min(10000, Math.max(1, deadline - now())),
    });
    if (!response.ok()) {
      // A browser request event (or even SSE HTTP200 headers) precedes durable
      // admission. Only this typed absence is transient before first visibility.
      if (!observed && response.status() === 404) {
        const missing = await response.json();
        if (missing.schema === 'masc.keeper_chat_operation.error.v1' && missing.error === 'unknown_operation') {
          await page.waitForTimeout(250);
          continue;
        }
      }
      throw new Error('Browser operation lookup failed: HTTP ' + response.status());
    }
    const operation = await response.json();
    if (operation.schema !== 'masc.keeper_chat_operation.v1' || operation.operation_id !== requestId) {
      throw new Error('Browser operation identity or schema mismatch');
    }
    observed = true;
    if (['Succeeded', 'Failed', 'Cancelled'].includes(operation.state)) return operation;
    if (!['Queued', 'Running'].includes(operation.state)) throw new Error('Unknown browser operation state');
    await page.waitForTimeout(250);
  }
  throw new Error(observed ? 'Browser operation did not settle before deadline' : 'Browser operation was not admitted before deadline');
}

async function main() {
  const [baseUrl, tokenFile, outputDir, playwrightModule, browserExecutable] = process.argv.slice(2);
  const { chromium } = require(playwrightModule);
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
    // Text can precede settlement, and history hydration can replace SSE
    // presentation metadata. Read the exact durable operation before cleanup.
    const operationUrl = baseUrl + '/api/v1/keepers/imp/chat/operations/' + encodeURIComponent(requestId);
    const operation = await waitForDurableOperation(page, operationUrl, token, requestId);
    if (operation?.state !== 'Succeeded' || typeof operation.completed_at !== 'number' ||
        typeof operation.outcome_ref !== 'string' || !operation.outcome_ref) {
      throw new Error('Browser operation did not succeed with a durable terminal outcome');
    }
    const replySelector = await page.evaluate(({ id, outcome }) => {
      const complete = '[data-chat-role="assistant"][data-chat-stream-state="complete"]';
      return complete + '[data-chat-stream-contract-request-id="' + CSS.escape(id) + '"],' +
        complete + '[data-chat-turn-ref="' + CSS.escape(outcome) + '"]';
    }, { id: requestId, outcome: operation.outcome_ref });
    const reply = page.locator(replySelector).filter({ hasText: 'IMP_BROWSER_OK' }).last();
    await reply.waitFor({ timeout: 30000 });
    const gateObservation = await page.locator('.v2-statchip.attn').evaluateAll(nodes =>
      nodes.map(node => ({ label: node.textContent, detail: node.getAttribute('title') })));
    fs.writeFileSync(path.join(outputDir, 'browser-gate-observation.json'),
      JSON.stringify(gateObservation, null, 2).split(token).join('[REDACTED]'));
    await reply.scrollIntoViewIfNeeded();
    const textHandle = await page.waitForFunction(selector => {
      const matches = [...document.querySelectorAll(selector)];
      for (const node of matches.reverse()) {
        if (node.getClientRects().length && node.innerText?.includes('IMP_BROWSER_OK')) return node.innerText;
      }
      return false;
    }, replySelector, { timeout: 30000 });
    const assistantReply = await textHandle.jsonValue();
    await textHandle.dispose();
    await page.screenshot({ path: path.join(outputDir, 'imp-browser-chat.png'), fullPage: false });
    fs.writeFileSync(path.join(outputDir, 'browser-receipt.json'), JSON.stringify({
      url: page.url(), keeper: 'imp', interaction: 'typed and sent a real chat message',
      assistantReply, requestId, terminalState: operation.state,
      completedAt: operation.completed_at, outcomeRef: operation.outcome_ref,
      terminalEvidenceSource: 'durable_chat_operation', streamState: 'complete', fixtureModel: false,
    }, null, 2));
  } finally {
    await browser.close();
  }
}

module.exports = { waitForDurableOperation };
if (require.main === module) main().catch(error => { process.stderr.write(error.message + '\n'); process.exitCode = 1; });
