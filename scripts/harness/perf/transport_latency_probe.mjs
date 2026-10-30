#!/usr/bin/env node
/** Read-only same-method transport comparison, Node 26+.
 * HTTP JSON / finite POST SSE / WS invoke ping or tools/list, never tools/call.
 * https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
 */
import http from 'node:http';
import https from 'node:https';
import { readFile, writeFile } from 'node:fs/promises';
import { performance } from 'node:perf_hooks';
import { createHash } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';

const options = { samples: 30, interval: 1200, timeout: 10000, tokenEnv: 'MCP_TOKEN', method: 'ping' };
for (let i = 2; i < process.argv.length; i += 2) {
  const value = process.argv[i + 1];
  if (!value) throw new Error(`Missing value for ${process.argv[i]}`);
  switch (process.argv[i]) {
    case '--base-url': options.baseUrl = value; break;
    case '--output': options.output = value; break;
    case '--samples': options.samples = Number(value); break;
    case '--interval-ms': options.interval = Number(value); break;
    case '--timeout-ms': options.timeout = Number(value); break;
    case '--token-env': options.tokenEnv = value; break;
    case '--method': options.method = value; break;
    default: throw new Error(`Unknown option ${process.argv[i]}`);
  }
}
if (!options.baseUrl || !options.output || !Number.isSafeInteger(options.samples)
    || options.samples < 1 || !Number.isFinite(options.interval) || options.interval < 0
    || !Number.isFinite(options.timeout) || options.timeout <= 0
    || !['ping', 'tools/list'].includes(options.method)) {
  throw new Error('Required: --base-url ORIGIN --output FILE [--samples N] [--interval-ms N] [--timeout-ms N]');
}
const base = new URL(options.baseUrl);
if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password
    || base.pathname !== '/' || base.search || base.hash) throw new Error('Expected an HTTP(S) origin');
const token = process.env[options.tokenEnv];
const protocol = '2025-11-25';
const transport = base.protocol === 'https:' ? https : http;
const agents = [];
const sessions = [];
const setup = [];
const cleanup = [];
const samples = [];
const warmup = [];
const diagnostics = [];
let socket;
let id = 0;
let pending;
let pushedMessages = 0;
let pushedPayloads = 0;
let pushedBytes = 0;
let socketFailure;

function safeError(error) {
  const kinds = new Set(['Error', 'TypeError', 'SyntaxError', 'RangeError', 'AbortError', 'TimeoutError']);
  const codes = new Set(['ECONNREFUSED', 'ECONNRESET', 'ECONNABORTED', 'ETIMEDOUT', 'EPIPE',
    'ENOTFOUND', 'EAI_AGAIN', 'ERR_STREAM_PREMATURE_CLOSE', 'ERR_INVALID_URL',
    'ERR_INVALID_ARG_TYPE', 'UND_ERR_CONNECT_TIMEOUT', 'UND_ERR_SOCKET']);
  const kind = kinds.has(error?.name) ? error.name : 'UnknownError';
  const code = error?.code ?? error?.cause?.code;
  return { kind, ...(Number.isSafeInteger(code) || codes.has(code) ? { code } : {}) };
}

function client() {
  const agent = new transport.Agent({ keepAlive: true, maxSockets: 1 });
  agents.push(agent);
  return agent;
}
const control = client();
async function request(agent, path, { method = 'GET', payload, headers = {} } = {}) {
  const body = payload === undefined ? '' : JSON.stringify(payload);
  const start = performance.now();
  return new Promise((resolve, reject) => {
    const req = transport.request(new URL(path, base), {
      agent, method, signal: AbortSignal.timeout(options.timeout),
      headers: { Accept: 'application/json', 'Accept-Encoding': 'identity',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(payload === undefined ? {} : { 'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body) }), ...headers },
    }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('error', reject);
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers,
        text: Buffer.concat(chunks).toString('utf8'), request_body_bytes: Buffer.byteLength(body),
        response_body_bytes: chunks.reduce((n, chunk) => n + chunk.length, 0),
        body_received_ms: performance.now() - start, reused_socket: req.reusedSocket }));
    });
    req.on('error', reject);
    req.end(body);
  });
}
function messages(text, contentType) {
  if (contentType.split(';')[0].trim() === 'application/json') return [JSON.parse(text)];
  if (contentType.split(';')[0].trim() !== 'text/event-stream') throw new Error('Unexpected response media type');
  return text.replaceAll('\r\n', '\n').split('\n\n').flatMap(frame => {
    const data = frame.split('\n').filter(line => line.startsWith('data:'))
      .map(line => line.slice(5).trimStart()).join('\n');
    return data ? [JSON.parse(data)] : [];
  });
}
function rpcResult(message, expectedId) {
  if (message?.jsonrpc !== '2.0' || message.id !== expectedId || message.error
      || !Object.hasOwn(message, 'result')) throw Object.assign(new Error('Invalid JSON-RPC reply'),
        { code: message?.error?.code });
  return message.result;
}
function resultIdentity(value) {
  function canonical(value) {
    if (Array.isArray(value)) return value.map(canonical);
    if (value && typeof value === 'object') return Object.fromEntries(
      Object.keys(value).sort().map(key => [key, canonical(value[key])]));
    return value;
  }
  return createHash('sha256').update(JSON.stringify(canonical(value))).digest('hex');
}
async function health() {
  const row = await request(control, '/health?full=1');
  if (row.status !== 200) throw new Error(`Health HTTP ${row.status}`);
  const value = JSON.parse(row.text);
  const build = value.build;
  const identity = Object.fromEntries(['runtime_instance_id', 'binary_commit', 'executable_sha256']
    .map(key => [key, build?.[key]]));
  if (Object.values(identity).some(value => typeof value !== 'string' || !value.trim())) {
    throw new Error('Missing runtime identity');
  }
  return { identity, scheduler: value.scheduler, runtime: value.runtime,
    overall_status: value.overall_status };
}
async function httpLane(name, accept, expectedMedia) {
  const agent = client();
  const initialized = await request(agent, '/mcp', { method: 'POST',
    headers: { Accept: 'application/json, text/event-stream' }, payload: {
      jsonrpc: '2.0', id: ++id, method: 'initialize', params: { protocolVersion: protocol,
        capabilities: {}, clientInfo: { name: 'masc-transport-latency-probe', version: '1' } } } });
  const session = initialized.headers['mcp-session-id'];
  // Track even a malformed initialize's allocated session for cleanup.
  if (session) sessions.push({ agent, session });
  if (initialized.status !== 200 || !session) throw new Error(`Initialize HTTP ${initialized.status} or missing session`);
  const result = rpcResult(messages(initialized.text, initialized.headers['content-type'] ?? '')[0], id);
  if (result.protocolVersion !== protocol) throw new Error('Unexpected MCP protocol');
  const headers = { Accept: accept, 'Mcp-Session-Id': session, 'MCP-Protocol-Version': protocol,
    ...(expectedMedia === 'application/json' ? { 'X-Masc-Force-Json': 'true' } : {}) };
  const notified = await request(agent, '/mcp', { method: 'POST', headers,
    payload: { jsonrpc: '2.0', method: 'notifications/initialized' } });
  if (notified.status !== 202) throw new Error(`Initialized HTTP ${notified.status}`);
  return { name, async ping(requestId) {
    const started = performance.now();
    const cpu = process.cpuUsage();
    const row = await request(agent, '/mcp', { method: 'POST', headers,
      payload: { jsonrpc: '2.0', id: requestId, method: options.method } });
    const evidence = { status: row.status, body_received_ms: row.body_received_ms,
      reused_socket: row.reused_socket, request_body_bytes: row.request_body_bytes,
      response_body_bytes: row.response_body_bytes, media_type: row.headers['content-type'] };
    if (row.status !== 200) return { ...evidence, valid: false, error: `HTTP ${row.status}` };
    const actual = (row.headers['content-type'] ?? '').split(';')[0].trim();
    if (actual !== expectedMedia) return { ...evidence, valid: false, error: 'Requested response encoding not served' };
    const replies = messages(row.text, actual).filter(message => message?.id === requestId);
    if (replies.length !== 1) throw new Error('Expected exactly one matching RPC reply');
    const value = rpcResult(replies[0], requestId);
    const total = performance.now() - started;
    const clientCpu = process.cpuUsage(cpu);
    return { ...evidence, valid: true, result_sha256: resultIdentity(value),
      total_ms: total, client_cpu_us: clientCpu.user + clientCpu.system };
  } };
}
async function wsRequest(method, params, requestId = ++id) {
  if (socketFailure) throw new Error(socketFailure);
  const start = performance.now();
  const cpu = process.cpuUsage();
  const body = JSON.stringify({ jsonrpc: '2.0', id: requestId, method, ...(params ? { params } : {}) });
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending = undefined; reject(new Error('WS request timeout')); }, options.timeout);
    pending = { id: requestId, resolve: (message, bytes) => {
      clearTimeout(timer);
      try {
        const value = rpcResult(message, requestId);
        const total = performance.now() - start;
        const clientCpu = process.cpuUsage(cpu);
        resolve({ value, total_ms: total, client_cpu_us: clientCpu.user + clientCpu.system,
          request_body_bytes: Buffer.byteLength(body), response_body_bytes: bytes });
      }
      catch (error) { reject(error); }
    }, reject: error => { clearTimeout(timer); reject(error); } };
    try { socket.send(body); } catch (error) { pending = undefined; clearTimeout(timer); reject(error); }
  });
}
async function wsLane() {
  const discovery = await request(control, '/ws');
  if (discovery.status !== 200) throw new Error(`WS discovery HTTP ${discovery.status}`);
  const config = JSON.parse(discovery.text);
  const target = new URL(config.ws_url);
  const expected = new URL(base);
  expected.protocol = base.protocol === 'https:' ? 'wss:' : 'ws:';
  if (!config.enabled || target.origin !== expected.origin) throw new Error('WS listener is unavailable or cross-origin');
  socket = new WebSocket(target, { headers: { Origin: base.origin } });
  const fail = message => {
    socketFailure = message;
    if (pending) { const waiting = pending; pending = undefined; waiting.reject(new Error(message)); }
  };
  socket.addEventListener('error', () => fail('WS connection error'));
  socket.addEventListener('close', () => fail('WS connection closed'));
  socket.addEventListener('message', event => {
    const raw = String(event.data);
    let decoded;
    try { decoded = messages(raw, 'application/json'); }
    catch {
      try { decoded = messages(raw, 'text/event-stream'); }
      catch { fail('Malformed WS message'); return; }
    }
    let unsolicited = 0;
    for (const message of decoded) {
      if (pending && message?.id === pending.id) {
        const waiting = pending; pending = undefined;
        waiting.resolve(message, Buffer.byteLength(raw));
      } else { unsolicited++; }
    }
    if (unsolicited) {
      pushedMessages++;
      pushedPayloads += unsolicited;
      // Count the physical message once, even when it contains several SSE payloads.
      // A mixed RPC/push message also contributes to response_body_bytes; these are not additive.
      pushedBytes += Buffer.byteLength(raw);
    }
  });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('WS open timeout')), options.timeout);
    socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
    socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error('WS open failed')); }, { once: true });
  });
  const hello = await wsRequest('dashboard/hello', { protocol: 'dashboard-ws.v1', features: [],
    ...(token ? { token } : {}) });
  if (hello.value?.session?.authenticated !== true) throw new Error('WS hello was not authenticated');
  // Use the exact generic MCP method/result, rather than dashboard/ping's different work.
  return { name: 'ws', async ping(requestId) {
    const { value, ...row } = await wsRequest(options.method, undefined, requestId);
    return { ...row, valid: true, result_sha256: resultIdentity(value) };
  } };
}
function percentile(values, p) {
  return values.length ? values[Math.ceil(p * values.length) - 1] : null;
}
let before = null;
let after = null;
try {
  before = await health();
  const lanes = [];
  for (const [name, factory] of [
    ['http_json', () => httpLane('http_json', 'application/json, text/event-stream', 'application/json')],
    ['http_sse', () => httpLane('http_sse', 'application/json, text/event-stream', 'text/event-stream')],
    ['ws', wsLane],
  ]) {
    const start = performance.now();
    try { lanes.push(await factory()); setup.push({ name, valid: true, total_ms: performance.now() - start }); }
    catch (error) { setup.push({ name, valid: false, error: safeError(error) }); }
  }
  for (const lane of lanes) {
    try { warmup.push({ transport: lane.name, ...await lane.ping(++id) }); }
    catch (error) { warmup.push({ transport: lane.name, valid: false, error: safeError(error) }); }
  }
  for (let round = 0; round < options.samples; round++) {
    if (round) await sleep(options.interval);
    // Rotate first/second/third positions so ambient load does not always favor one lane.
    for (let index = 0; index < lanes.length; index++) {
      const lane = lanes[(round + index) % lanes.length];
      const start = performance.now();
      try { samples.push({ transport: lane.name, round, order: index, ...await lane.ping(++id) }); }
      catch (error) { samples.push({ transport: lane.name, round, order: index, valid: false,
        elapsed_ms: performance.now() - start, error: safeError(error) }); }
    }
  }
} catch (error) {
  diagnostics.push({ phase: before ? 'measurement' : 'initial_health', error: safeError(error) });
} finally {
  if (socket) {
    let timer;
    let onClose;
    try {
      const closed = await new Promise(resolve => {
        if (socket.readyState === WebSocket.CLOSED) { resolve(true); return; }
        onClose = () => resolve(true);
        socket.addEventListener('close', onClose, { once: true });
        timer = setTimeout(() => resolve(false), options.timeout);
        socket.close(1000, 'measurement complete');
      });
      cleanup.push({ transport: 'ws', closed });
    } catch (error) {
      cleanup.push({ transport: 'ws', closed: false, error: safeError(error) });
    } finally {
      clearTimeout(timer);
      if (onClose) socket.removeEventListener('close', onClose);
    }
  }
  for (const { agent, session } of sessions) {
    try {
      const row = await request(agent, '/mcp', { method: 'DELETE', headers: {
        'Mcp-Session-Id': session, 'MCP-Protocol-Version': protocol } });
      cleanup.push({ transport: 'http', status: row.status, valid: row.status === 204 });
    } catch (error) { cleanup.push({ transport: 'http', valid: false, error: safeError(error) }); }
  }
  try { after = await health(); }
  catch (error) { diagnostics.push({ phase: 'final_health', error: safeError(error) }); }
  for (const agent of agents) agent.destroy();
}
const expectedResult = warmup.find(row => row.transport === 'http_json' && row.valid)?.result_sha256;
for (const row of [...warmup, ...samples]) {
  if (row.valid && (!expectedResult || row.result_sha256 !== expectedResult)) {
    row.valid = false;
    row.error = 'RPC result differs from the HTTP JSON reference';
  }
}
const summary = Object.fromEntries(['http_json', 'http_sse', 'ws'].map(name => {
  const rows = samples.filter(row => row.transport === name);
  const times = rows.filter(row => row.valid).map(row => row.total_ms).sort((a, b) => a - b);
  const cpus = rows.filter(row => row.valid).map(row => row.client_cpu_us).sort((a, b) => a - b);
  return [name, { attempted: rows.length, valid: times.length,
    failures: rows.length - times.length, p50_ms: percentile(times, .5), p95_ms: percentile(times, .95),
    max_ms: times.at(-1) ?? null, client_cpu_p50_us: percentile(cpus, .5),
    request_body_bytes: rows.reduce((n, row) => n + (row.request_body_bytes ?? 0), 0),
    response_body_bytes: rows.reduce((n, row) => n + (row.response_body_bytes ?? 0), 0) }];
}));
const sameRuntime = Boolean(before && after) && JSON.stringify(before.identity) === JSON.stringify(after.identity);
const report = { schema: 'masc.transport_latency.v1', recorded_at: new Date().toISOString(),
  runner_sha256: createHash('sha256').update(await readFile(new URL(import.meta.url))).digest('hex'),
  base_url: base.origin, node_version: process.version, options: { samples: options.samples,
    interval_ms: options.interval, timeout_ms: options.timeout, method: options.method }, authenticated: Boolean(token),
  scope: 'Read-only same-method MCP requests; rotating sequential warm connections. Setup excluded. HTTP JSON uses the MASC force-JSON header with both MCP Accept types. HTTP SSE means finite POST response, not observer push. Body bytes exclude headers, framing and TLS. Ambient server CPU/RSS are not attributable to one transport. No throughput or browser-render claim.',
  timing_scope: 'total_ms ends after parsing and JSON-RPC ID/result validation, before canonical hash calculation in every lane. One method warmup per lane is separately retained. client_cpu_us is this Node process CPU during that request window, including unsolicited WS traffic, not server or browser CPU.',
  before, after, same_runtime: sameRuntime, setup, warmup, cleanup, summary, samples, diagnostics,
  ws_unsolicited: { messages: pushedMessages, payloads: pushedPayloads, body_bytes: pushedBytes },
  passed: sameRuntime && diagnostics.length === 0 && setup.length === 3 && setup.every(row => row.valid)
    && warmup.length === 3 && warmup.every(row => row.valid)
    && samples.length === options.samples * 3 && samples.every(row => row.valid)
    && cleanup.every(row => row.transport === 'ws' ? row.closed : row.valid) };
await writeFile(options.output, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify({ passed: report.passed, same_runtime: sameRuntime, setup, summary, cleanup, diagnostics }, null, 2));
process.exitCode = report.passed ? 0 : 1;
