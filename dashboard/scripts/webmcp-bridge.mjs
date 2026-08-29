#!/usr/bin/env node
// MASC — WebMCP consumer bridge (experiment lane, manual harness)
//
// Drives a headed Chrome over CDP and calls the WebMCP tools a page has
// registered on document.modelContext. The first target is the masc dashboard
// itself (dashboard/src/api/webmcp.ts registers the read-only allowlist), so
// the whole outbound pipeline is verifiable without any external site:
//   bridge → CDP → page.executeTool → dashboard fetch → masc server.
//
// Chrome prerequisites (WebMCP ships headed-only, Chrome 149+):
//   "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
//     --user-data-dir=/tmp/masc-webmcp-profile \
//     --remote-debugging-port=9222 \
//     --enable-features=WebMCP \
//     "http://localhost:8935/?token=<dashboard token>"
//
// Usage:
//   node scripts/webmcp-bridge.mjs list [--port 9222] [--page localhost:8935]
//   node scripts/webmcp-bridge.mjs call <tool> [jsonArgs] [--port ...] [--page ...]
//   node scripts/webmcp-bridge.mjs loop-check [--port ...] [--page ...]
//   node scripts/webmcp-bridge.mjs detect [--port 9222] [--expect-external]
//
// `detect` scans every open tab and reports which expose WebMCP tools. It is
// the ecosystem sensor for RFC-webmcp-capability-lanes Lane D: run it against a
// browser with a candidate site open (Expedia, Shopify, …) and it says whether
// that site has begun serving document.modelContext tools. --expect-external
// turns it into a trigger check — exit 0 only when a non-localhost origin
// exposes a surface, so a scheduled run stays silent until the ecosystem flips.
//
// Exit codes: 0 ok, 1 unexpected failure, 2 target page not found,
//             3 loop-check assertion failed, 4 detect --expect-external found none.

const args = process.argv.slice(2)
const command = args[0]

function flagValue(name, fallback) {
  const index = args.indexOf(`--${name}`)
  return index >= 0 && args[index + 1] !== undefined ? args[index + 1] : fallback
}

const port = flagValue('port', '9222')
const pageNeedle = flagValue('page', 'localhost:8935')

async function findPage() {
  let targets
  try {
    targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()
  } catch (error) {
    // An unreachable CDP endpoint is the same operator condition as a missing
    // page: Chrome is not up in the expected shape. Same exit code.
    console.error(`CDP endpoint 127.0.0.1:${port} unreachable: ${error}`)
    process.exit(2)
  }
  const page = targets.find(t => t.type === 'page' && t.url.includes(pageNeedle))
  if (!page) {
    console.error(`page matching "${pageNeedle}" not found on CDP port ${port}; pages:`)
    for (const t of targets.filter(t => t.type === 'page')) console.error(`  ${t.url}`)
    process.exit(2)
  }
  return page
}

function connect(page) {
  const ws = new WebSocket(page.webSocketDebuggerUrl)
  let nextId = 0
  const pending = new Map()
  ws.onmessage = (event) => {
    const message = JSON.parse(event.data)
    if (message.id && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id)
      pending.delete(message.id)
      if (message.error) reject(new Error(JSON.stringify(message.error)))
      else resolve(message.result)
    }
  }
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++nextId
    pending.set(id, { resolve, reject })
    ws.send(JSON.stringify({ id, method, params }))
  })
  const opened = new Promise(resolve => { ws.onopen = resolve })
  return { ws, send, opened }
}

// Runs an expression in page context. The expression must resolve to a JSON
// string (serialize page-side): CDP returnByValue drops non-cloneable members.
async function evaluateJson(send, expression) {
  const result = await send('Runtime.evaluate', {
    expression,
    awaitPromise: true,
    returnByValue: true,
  })
  if (result.exceptionDetails) {
    const detail = result.exceptionDetails.exception?.description
      ?? JSON.stringify(result.exceptionDetails)
    throw new Error(`page evaluation failed: ${detail}`)
  }
  return JSON.parse(result.result.value)
}

const LIST_TOOLS_EXPR = `(async () => {
  if (!document.modelContext) return JSON.stringify({ surface: false, tools: [] })
  const tools = await document.modelContext.getTools()
  return JSON.stringify({
    surface: true,
    tools: tools.map(t => ({ name: t.name, description: t.description, origin: t.origin })),
  })
})()`

// WebMCP contract measured on Chrome 151 (evidence record 2026-08-29):
// executeTool takes the RegisteredTool object plus a JSON *string* of
// arguments, and resolves to a JSON string of MCP-style content.
function callToolExpr(toolName, toolArgs) {
  return `(async () => {
    const tools = await document.modelContext.getTools()
    const tool = tools.find(t => t.name === ${JSON.stringify(toolName)})
    if (!tool) return JSON.stringify({ found: false })
    const raw = await document.modelContext.executeTool(
      tool,
      ${JSON.stringify(JSON.stringify(toolArgs))},
    )
    return JSON.stringify({ found: true, result: JSON.parse(raw) })
  })()`
}

async function withPage(run) {
  const page = await findPage()
  const { ws, send, opened } = connect(page)
  await opened
  try {
    return await run(send)
  } finally {
    ws.close()
  }
}

async function listCommand() {
  const listing = await withPage(send => evaluateJson(send, LIST_TOOLS_EXPR))
  console.log(JSON.stringify(listing, null, 2))
  if (!listing.surface) process.exit(3)
}

async function callCommand() {
  const toolName = args[1]
  if (!toolName || toolName.startsWith('--')) {
    console.error('usage: webmcp-bridge.mjs call <tool> [jsonArgs]')
    process.exit(1)
  }
  const rawArgs = args[2] && !args[2].startsWith('--') ? args[2] : '{}'
  const outcome = await withPage(send =>
    evaluateJson(send, callToolExpr(toolName, JSON.parse(rawArgs))))
  console.log(JSON.stringify(outcome, null, 2))
  if (!outcome.found) process.exit(3)
}

// Reports a page's WebMCP surface without asserting anything. Returns the tool
// count and, when present, the origin the tools declare — the origin, not the
// tab URL, is what a cross-origin frame's tools carry.
const SURFACE_PROBE_EXPR = `(async () => {
  if (!document.modelContext) return JSON.stringify({ surface: false, count: 0 })
  const tools = await document.modelContext.getTools()
  return JSON.stringify({
    surface: true,
    count: tools.length,
    names: tools.map(t => t.name),
    origins: [...new Set(tools.map(t => t.origin).filter(Boolean))],
  })
})()`

function isExternalOrigin(url) {
  try {
    const host = new URL(url).hostname
    return host !== 'localhost' && host !== '127.0.0.1' && host !== '[::1]'
  } catch {
    return false
  }
}

// Ecosystem sensor: probe every open tab, report which expose WebMCP.
async function detectCommand() {
  const expectExternal = args.includes('--expect-external')
  let targets
  try {
    targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()
  } catch (error) {
    console.error(`CDP endpoint 127.0.0.1:${port} unreachable: ${error}`)
    process.exit(2)
  }
  const pages = targets.filter(t => t.type === 'page' && /^https?:/.test(t.url))
  const report = []
  for (const page of pages) {
    const { ws, send, opened } = connect(page)
    await opened
    try {
      const probe = await evaluateJson(send, SURFACE_PROBE_EXPR)
      report.push({ url: page.url, external: isExternalOrigin(page.url), ...probe })
    } catch (error) {
      report.push({ url: page.url, external: isExternalOrigin(page.url), surface: false, count: 0, error: String(error) })
    } finally {
      ws.close()
    }
  }
  const withSurface = report.filter(r => r.surface && r.count > 0)
  const externalSurface = withSurface.filter(r => r.external)
  console.log(JSON.stringify({ scanned: pages.length, withSurface: withSurface.length, externalSurface: externalSurface.length, pages: report }, null, 2))
  if (expectExternal && externalSurface.length === 0) process.exit(4)
}

// Deterministic round-trip assertions against the dashboard's own surface.
async function loopCheckCommand() {
  const failures = []
  await withPage(async (send) => {
    const listing = await evaluateJson(send, LIST_TOOLS_EXPR)
    if (!listing.surface) {
      failures.push('document.modelContext is absent — Chrome lacks --enable-features=WebMCP')
      return
    }
    const names = listing.tools.map(t => t.name)
    if (!names.includes('masc_status')) {
      failures.push(`masc_status not registered (tools: ${names.join(', ') || 'none'})`)
      return
    }
    const status = await evaluateJson(send, callToolExpr('masc_status', {}))
    const statusText = status.result?.content?.[0]?.text
    if (typeof statusText !== 'string' || statusText.trim() === '') {
      failures.push(`masc_status returned no text: ${JSON.stringify(status)}`)
    }
    const tasks = await evaluateJson(send, callToolExpr('masc_tasks', {}))
    const tasksText = tasks.result?.content?.[0]?.text
    if (typeof tasksText !== 'string' || tasksText.trim() === '') {
      failures.push(`masc_tasks returned no text: ${JSON.stringify(tasks)}`)
    }
    console.log(`tools registered: ${names.join(', ')}`)
    console.log(`masc_status text bytes: ${statusText?.length ?? 0}`)
    console.log(`masc_tasks text bytes: ${tasksText?.length ?? 0}`)
  })
  if (failures.length > 0) {
    for (const failure of failures) console.error(`FAIL: ${failure}`)
    process.exit(3)
  }
  console.log('loop-check: ok')
}

switch (command) {
  case 'list':
    await listCommand()
    break
  case 'call':
    await callCommand()
    break
  case 'loop-check':
    await loopCheckCommand()
    break
  case 'detect':
    await detectCommand()
    break
  default:
    console.error('usage: webmcp-bridge.mjs <list|call|loop-check|detect> [--port 9222] [--page localhost:8935]')
    process.exit(1)
}
