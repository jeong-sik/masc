/** Real browser + real ocamllsp, with a test-only JSON-RPC transport adapter.
 * Uses Vite's development transformer; performs no production or native build.
 * This proves the source client/CM behavior, not the installed MASC proxy.
 * Usage: node scripts/lsp-editor-browser-probe.mjs DASHBOARD OCAMLLSP OUTPUT
 */
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { mkdir, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { spawn } from 'node:child_process'

const [dashboardArg, languageServer, outputArg] = process.argv.slice(2)
assert.ok(dashboardArg && languageServer && outputArg, 'DASHBOARD OCAMLLSP OUTPUT required')
const dashboard = resolve(dashboardArg), output = resolve(outputArg)
const require = createRequire(resolve(dashboard, 'package.json'))
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { chromium } = require('playwright')
const { WebSocketServer } = createRequire(require.resolve('jsdom'))('ws')
await mkdir(resolve(output, 'workspace'), { recursive: true })
await writeFile(resolve(output, 'workspace/sample.ml'), 'let value =\n')
const workspace = resolve(output, 'workspace')
const protocol = [], pageErrors = [], children = new Set()
let browser, vite, sockets, page
const receipt = { scope: 'Source CodeMirror client in a real browser, real ocamllsp through a test-only adapter. Not installed MASC, Keeper execution, or MASC proxy acceptance.', passed: false }
try {
  vite = await createServer({ configFile: false, root: dashboard, cacheDir: resolve(output, 'vite-cache'),
    server: { host: '127.0.0.1', port: 0 }, logLevel: 'error',
    plugins: [{ name: 'lsp-document-browser-fixture', configureServer(server) {
      server.middlewares.use('/__lsp_probe', async (_req, res) => {
        res.setHeader('Content-Type', 'text/html')
        res.end(await server.transformIndexHtml('/__lsp_probe', '<!doctype html><meta charset="UTF-8"><title>LSP source continuity probe</title><style>:root{--color-fg-error:#c33;--color-fg-warning:#b70;--color-fg-info:#169}body{font:16px sans-serif;margin:40px;background:#18202b;color:#fff}#status{padding:16px}#editor{background:white;color:black;min-height:220px}</style><h1>Selected file: sample.ml</h1><p id="status" role="status"></p><div id="editor"></div><script type="module" src="/scripts/lsp-document-browser-fixture.ts"></script>'))
      })
    } }],
  })
  sockets = new WebSocketServer({ noServer: true })
  vite.httpServer.on('upgrade', (request, socket, head) => {
    if (new URL(request.url, 'http://localhost').pathname === '/api/v1/ide/lsp') {
      sockets.handleUpgrade(request, socket, head, ws => sockets.emit('connection', ws))
    }
  })
  sockets.on('connection', ws => {
    const child = spawn(languageServer, [], { cwd: workspace, stdio: ['pipe', 'pipe', 'pipe'] })
    children.add(child)
    let buffered = Buffer.alloc(0), initializeId
    const send = message => {
      const body = Buffer.from(JSON.stringify(message))
      child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`)
      child.stdin.write(body)
    }
    child.on('error', error => { protocol.push({ stage: 'spawn', error: String(error) }); ws.close(1011) })
    child.on('exit', (code, signal) => { protocol.push({ stage: 'server_exit', code, signal }); children.delete(child) })
    child.stderr.on('data', data => protocol.push({ direction: 'stderr', text: data.toString() }))
    child.stdout.on('data', data => {
      buffered = Buffer.concat([buffered, data])
      for (;;) {
        const boundary = buffered.indexOf('\r\n\r\n')
        if (boundary < 0) break
        const length = /^Content-Length:\s*(\d+)$/mi.exec(buffered.subarray(0, boundary).toString())
        assert.ok(length, 'language server response framing')
        const size = Number(length[1]), end = boundary + 4 + size
        if (buffered.length < end) break
        const message = JSON.parse(buffered.subarray(boundary + 4, end).toString())
        buffered = buffered.subarray(end)
        protocol.push({ direction: 'server', message })
        if (message.id === initializeId && message.result) {
          message.result.masc = { workspaceRoot: workspace }
          ws.send(JSON.stringify(message))
          ws.send(JSON.stringify({ jsonrpc: '2.0', method: 'masc/lspStatus', params: {
            langs: [{ lang: 'ocaml', connected: true, command: languageServer, last_error: null }],
          } }))
        } else if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(message))
      }
    })
    ws.on('message', raw => {
      const message = JSON.parse(raw.toString())
      protocol.push({ direction: 'client', message: structuredClone(message) })
      if (message.method === 'initialize') {
        initializeId = message.id
        message.params.rootUri = pathToFileURL(workspace).href
        message.params.processId = process.pid
      }
      send(message)
    })
    ws.on('close', () => child.kill('SIGTERM'))
  })
  await vite.listen()
  const address = vite.httpServer.address()
  assert.ok(address && typeof address === 'object')
  browser = await chromium.launch({ headless: true })
  page = await browser.newPage({ viewport: { width: 1100, height: 700 } })
  page.on('pageerror', error => pageErrors.push(error.message))
  await page.goto(`http://127.0.0.1:${address.port}/__lsp_probe`)
  await page.waitForFunction(() => window.lspProbe?.snapshot()?.diagnostics.kind === 'complete'
    && window.lspProbe.snapshot().diagnostics.count > 0)
  receipt.initial = await page.evaluate(() => window.lspProbe.snapshot())
  assert.equal(receipt.initial.version, 1)
  await page.locator('.cm-diagnostic-marker[title]:not([title=""])').first().waitFor()
  receipt.initial_markers = await page.locator('.cm-diagnostic-marker[title]:not([title=""])').count()
  await page.screenshot({ path: resolve(output, 'invalid-document.png') })
  await page.evaluate(() => window.lspProbe.update('let value = 1\n'))
  await page.waitForFunction(() => window.lspProbe?.snapshot()?.version === 2
    && window.lspProbe.snapshot().diagnostics.kind === 'unversioned'
    && window.lspProbe.snapshot().diagnostics.count === 0)
  receipt.updated = await page.evaluate(() => window.lspProbe.snapshot())
  receipt.visible_status = await page.locator('#status').innerText()
  assert.match(receipt.visible_status, /0 reported.*version unconfirmed/)
  await page.locator('.cm-diagnostic-marker[title]:not([title=""])').first().waitFor({ state: 'detached' })
  receipt.updated_markers = await page.locator('.cm-diagnostic-marker[title]:not([title=""])').count()
  await page.screenshot({ path: resolve(output, 'updated-document.png') })
  assert.ok(protocol.some(event => event.direction === 'client' && event.message?.method === 'textDocument/didOpen'
    && event.message.params.textDocument.text === 'let value =\n'))
  assert.ok(protocol.some(event => event.direction === 'client' && event.message?.method === 'textDocument/didChange'
    && event.message.params.textDocument.version === 2
    && event.message.params.contentChanges[0].text === 'let value = 1\n'))
  assert.deepEqual(pageErrors, [])
  receipt.passed = true
} catch (error) {
  receipt.error = String(error)
  process.exitCode = 1
} finally {
  if (page) {
    receipt.final_document = await page.evaluate(() => window.lspProbe?.snapshot()).catch(() => null)
    await page.screenshot({ path: resolve(output, 'final.png') }).catch(() => {})
    await page.evaluate(() => window.lspProbe?.dispose()).catch(() => {})
  }
  if (browser) await browser.close()
  for (const child of children) child.kill('SIGTERM')
  if (sockets) for (const socket of sockets.clients) socket.terminate()
  if (vite) await vite.close()
  if (sockets) sockets.close()
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify({ ...receipt, pageErrors }, null, 2) + '\n')
  await writeFile(resolve(output, 'protocol.json'), JSON.stringify(protocol, null, 2) + '\n')
}
console.log(JSON.stringify({ output, passed: receipt.passed, error: receipt.error }))
