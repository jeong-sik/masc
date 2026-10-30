#!/usr/bin/env node
/** Read-only protocol probe of an existing MASC. Requires Node 26+.
 * Opens temporary MCP/WS sessions; invokes no tools, broadcasts or Keeper work.
 * MCP contract: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
 */
import { writeFile } from 'node:fs/promises';
import { performance } from 'node:perf_hooks';

const options = { timeout: 45000, tokenEnv: 'MCP_TOKEN' };
for (let i = 2; i < process.argv.length; i += 2) {
  const key = process.argv[i];
  const value = process.argv[i + 1];
  if (!value) throw new Error(`Missing value for ${key}`);
  switch (key) {
    case '--base-url': options.baseUrl = value; break;
    case '--output': options.output = value; break;
    case '--timeout-ms': options.timeout = Number(value); break;
    case '--token-env': options.tokenEnv = value; break;
    default: throw new Error(`Unknown option ${key}`);
  }
}
if (!options.baseUrl || !options.output || !Number.isFinite(options.timeout) || options.timeout <= 0) {
  throw new Error('Required: --base-url ORIGIN --output FILE [--timeout-ms N] [--token-env NAME]');
}
const base = new URL(options.baseUrl);
if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password
    || base.pathname !== '/' || base.search || base.hash) {
  throw new Error('--base-url must be an HTTP(S) origin without credentials');
}
const token = process.env[options.tokenEnv];
const headers = { Accept: 'application/json, text/event-stream' };
if (token) headers.Authorization = `Bearer ${token}`;
const protocolVersion = '2025-11-25';
const sessions = new Set();
const checks = [];
async function check(name, operation) {
  const start = performance.now();
  try {
    const evidence = await operation();
    checks.push({ name, status: 'pass', duration_ms: performance.now() - start, evidence });
    return evidence;
  } catch (error) {
    // Keep payloads and credentials out of diagnostics, including rejected WS hello frames.
    checks.push({ name, status: 'fail', duration_ms: performance.now() - start,
      error: error instanceof Error ? error.message : 'Unknown probe failure' });
    return null;
  }
}
async function request(path, init = {}) {
  return fetch(new URL(path, base), { ...init, headers: { ...headers, ...init.headers },
    signal: AbortSignal.timeout(options.timeout) });
}
async function jsonRequest(path, init) {
  const response = await request(path, init);
  if (!response.ok) throw new Error(`HTTP ${response.status} at ${path.split('?')[0]}`);
  if (!response.headers.get('content-type')?.includes('application/json')) {
    await response.body?.cancel();
    throw new Error(`Expected JSON at ${path.split('?')[0]}`);
  }
  return { response, json: await response.json() };
}
async function rpc(session, id, method, params = {}) {
  const response = await request('/mcp', {
    method: 'POST', headers: { 'Content-Type': 'application/json',
      'Mcp-Session-Id': session, 'MCP-Protocol-Version': protocolVersion },
    body: JSON.stringify({ jsonrpc: '2.0', id, method, params }),
  });
  const json = await rpcResponse(response, id);
  if (json.id !== id || json.error || !Object.hasOwn(json, 'result')) {
    throw new Error(`Invalid JSON-RPC response for ${method}`);
  }
  return json.result;
}
async function rpcResponse(response, id) {
  if (!response.ok) throw new Error(`MCP HTTP ${response.status}`);
  const contentType = response.headers.get('content-type') ?? '';
  if (contentType.includes('application/json')) return response.json();
  if (!contentType.includes('text/event-stream')) {
    await response.body?.cancel();
    throw new Error('MCP response is neither JSON nor SSE');
  }
  const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
  let buffer = '';
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) throw new Error('MCP SSE closed before the matching response');
      buffer = (buffer + value).replaceAll('\r\n', '\n');
      let end;
      while ((end = buffer.indexOf('\n\n')) !== -1) {
        const frame = buffer.slice(0, end);
        buffer = buffer.slice(end + 2);
        const data = frame.split('\n').filter(line => line.startsWith('data:'))
          .map(line => line.slice(5).trimStart()).join('\n');
        if (!data) continue;
        const message = JSON.parse(data);
        if (message.id === id) return message;
      }
    }
  } finally { await reader.cancel(); }
}
async function initialize() {
  const response = await request('/mcp', { method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
      protocolVersion, capabilities: {}, clientInfo: { name: 'masc-live-transport-probe', version: '1' },
    } }),
  });
  const session = response.headers.get('mcp-session-id');
  if (session) sessions.add(session);
  const json = await rpcResponse(response, 1);
  if (!session || json.id !== 1 || json.error || !json.result?.serverInfo
      || json.result.protocolVersion !== protocolVersion) {
    throw new Error('MCP initialize did not establish the requested session/protocol');
  }
  const initialized = await request('/mcp', { method: 'POST', headers: {
    'Content-Type': 'application/json', 'Mcp-Session-Id': session,
    'MCP-Protocol-Version': protocolVersion,
  }, body: JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) });
  await initialized.body?.cancel();
  if (initialized.status !== 202) throw new Error(`MCP initialized returned ${initialized.status}`);
  return { session, server: json.result.serverInfo };
}

const health = await check('http.health', async () => {
  const { json } = await jsonRequest('/health?full=1');
  if (json.status !== 'ok') throw new Error('Server liveness is not ok');
  if (typeof json.build?.runtime_instance_id !== 'string' || !json.build.runtime_instance_id.trim()) {
    throw new Error('Initial runtime identity is missing');
  }
  return { binary_commit: json.build?.binary_commit, runtime_instance_id: json.build?.runtime_instance_id,
    overall_status: json.overall_status, overall_status_reasons: json.overall_status_reasons,
    base_path: json.paths?.effective_base_path };
});
await Promise.all([
  check('http.mcp', async () => {
    const { session, server } = await initialize();
    await rpc(session, 2, 'ping');
    const listed = await rpc(session, 3, 'tools/list');
    if (!Array.isArray(listed.tools) || listed.tools.length === 0) throw new Error('No tools returned');
    return { server: { name: server.name, version: server.version },
      ping: 'replied', tools_returned: listed.tools.length };
  }),
  check('sse.observer', async () => {
    const { session } = await initialize();
    const response = await request('/mcp?sse_kind=observer', {
      headers: { Accept: 'text/event-stream', 'Mcp-Session-Id': session,
        'MCP-Protocol-Version': protocolVersion },
    });
    try {
      if (!response.ok || !response.headers.get('content-type')?.includes('text/event-stream')) {
        throw new Error(`Observer SSE refused: HTTP ${response.status}`);
      }
      const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
      let buffer = '';
      let frames = 0;
      try {
        for (;;) {
          const { value, done } = await reader.read();
          if (done) throw new Error('Observer SSE closed before receiving an event or heartbeat');
          buffer += value;
          buffer = buffer.replaceAll('\r\n', '\n');
          let end;
          while ((end = buffer.indexOf('\n\n')) !== -1) {
            const frame = buffer.slice(0, end);
            buffer = buffer.slice(end + 2);
            frames++;
            const lines = frame.split('\n');
            const hasData = lines.some(line => line.startsWith('data:') && line.slice(5).trim());
            const heartbeat = lines.some(line => /^: (ping|keepalive)$/.test(line));
            if (hasData || heartbeat) {
              // A prime/header alone cannot pass. Verify an independent request while the stream is open.
              const closed = (async () => {
                for (;;) {
                  const next = await reader.read();
                  if (next.done) throw new Error('Observer SSE closed during HTTP ping');
                }
              })();
              await Promise.race([closed, rpc(session, 4, 'ping')]);
              return { status: response.status, frames_received: frames,
                delivery: hasData ? 'data_event' : 'heartbeat', concurrent_http_ping: 'replied' };
            }
          }
        }
      } finally { await reader.cancel(); }
    } finally { if (!response.body?.locked) await response.body?.cancel(); }
  }),
  check('ws.dashboard', async () => {
    const { json: discovery } = await jsonRequest('/ws');
    const target = new URL(discovery.ws_url);
    const expected = new URL(base);
    expected.protocol = base.protocol === 'https:' ? 'wss:' : 'ws:';
    if (!discovery.enabled || target.origin !== expected.origin) {
      throw new Error('WS discovery does not identify a same-origin listener');
    }
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(target, { headers: { Origin: base.origin } });
      let authenticated = false;
      let pushedFrames = 0;
      const timer = setTimeout(() => finish(new Error('WS hello/ping timed out')), options.timeout);
      function finish(error, evidence) {
        clearTimeout(timer);
        ws.onclose = ws.onerror = ws.onmessage = null;
        ws.close(1000, 'probe complete');
        if (error) reject(error); else resolve(evidence);
      }
      ws.onopen = () => ws.send(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'dashboard/hello',
        params: { protocol: 'dashboard-ws.v1', features: ['snapshot', 'delta', 'mode_snapshot'],
          ...(token ? { token } : {}) } }));
      ws.onerror = () => finish(new Error('WS connection error'));
      ws.onclose = event => finish(new Error(`WS closed before ping reply: ${event.code}`));
      ws.onmessage = event => {
        let message;
        try { message = JSON.parse(event.data); }
        catch {
          // This endpoint also forwards raw SSE pushes between JSON-RPC replies.
          // Validate their data encoding; only exact RPC IDs below prove a reply.
          try {
            let received = false;
            for (const frame of String(event.data).split(/\r?\n\r?\n/)) {
              const data = frame.split(/\r?\n/).filter(line => line.startsWith('data:'))
                .map(line => line.slice(5).trimStart()).join('\n');
              if (data) { JSON.parse(data); received = true; pushedFrames++; }
            }
            if (received) return;
          } catch { /* The actual RPC response is still required. */ }
          finish(new Error('WS sent neither JSON nor an SSE data push')); return;
        }
        if (message.id === 1 && !authenticated) {
          if (message.error || message.result?.session?.authenticated !== true) {
            finish(new Error('Dashboard hello was not authenticated')); return;
          }
          authenticated = true;
          ws.send(JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'dashboard/ping', params: {} }));
        } else if (message.id === 2 && authenticated) {
          if (message.error || !Object.hasOwn(message, 'result')) {
            finish(new Error('Dashboard ping failed')); return;
          }
          finish(null, { upgraded: true, authenticated, dashboard_ping: 'replied',
            sse_push_frames_received: pushedFrames });
        }
      };
    });
  }),
]);
for (const session of sessions) {
  await check('http.session_cleanup', async () => {
    const response = await request('/mcp', { method: 'DELETE', headers: {
      'Mcp-Session-Id': session, 'MCP-Protocol-Version': protocolVersion,
    } });
    await response.body?.cancel();
    if (!response.ok) throw new Error(`Temporary MCP session cleanup returned ${response.status}`);
    return { status: response.status };
  });
}
const after = await check('http.identity_after', async () => {
  const { json } = await jsonRequest('/health?full=1');
  if (typeof json.build?.runtime_instance_id !== 'string' || !json.build.runtime_instance_id.trim()) {
    throw new Error('Final runtime identity is missing');
  }
  if (json.build?.runtime_instance_id !== health?.runtime_instance_id) {
    throw new Error('Runtime changed during probe; transport results span different instances');
  }
  return { runtime_instance_id: json.build?.runtime_instance_id };
});
const report = { schema: 'masc.live_transport_probe.v1', recorded_at: new Date().toISOString(),
  base_url: base.origin, timeout_ms: options.timeout, authenticated: Boolean(token),
  runtime: health, checks, passed: Boolean(after) && checks.every(row => row.status === 'pass') };
await writeFile(options.output, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
process.exitCode = report.passed ? 0 : 1;
