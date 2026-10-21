// Run with `node docs/evidence/2026-10-20-plugin-management/proof-server.mjs`.
// Uses the Dashboard's installed development dependencies; writes no MASC files.
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
const evidence = dirname(fileURLToPath(import.meta.url));
const root = resolve(evidence, '../../..');
const require = createRequire(resolve(root, 'dashboard/package.json'));
const { createServer } = await import(require.resolve('vite'));
const { default: tailwind } = await import(require.resolve('@tailwindcss/vite'));
const { getStaticTOMLValue, parseTOML } = await import(require.resolve('toml-eslint-parser'));
const directory = '/fixture/.masc/config/lane-addons';
const manifest = '/fixture/packages/observation/lane.toml';
const events = [];
const documents = new Map();
const snapshot = { configuration: { directory, complete: true, issues: [], declarations: [] }, instances: [], rows: [], coverage: [] };
function add(id, application, enabled = true) {
  const instance = application.kind === 'applied' ? application.instance_id : null;
  snapshot.configuration.declarations.push({ id, source_path: `${directory}/${id}.toml`, enabled,
    source_revision: `file-${id}`, desired_revision: `input-${id}`,
    applied_revision: instance ? `input-${id}` : null, instance_id: instance, application });
  if (instance) snapshot.instances.push({ instance_id: instance, incarnation: `epoch-${id}`, runtime_presence: 'live',
    run_id: 'browser-work', addon_id: 'ego-browser', title: 'ego browser companion', revision: '0.1.0',
    action_schema: null, package: { outputs: { browser: { lanes: ['browser/session'] } }, binding_schema: null,
      presentation: { description: 'Captured native browser observations', readings: [] } },
    configuration: { id, source_path: `${directory}/${id}.toml`, revision: `input-${id}` },
    phase: { kind: 'attached' }, observation_seq: 3, rows_count: 2 });
}
add('ego-browser', { kind: 'applied', instance_id: 'worker-ego' });
add('paused-report', { kind: 'inactive' }, false);
add('new-report', { kind: 'starting' });
add('cleanup-failure', { kind: 'failed', messages: ['Worker cleanup failed; retained resource still needs recovery'] }, false);
add('old-browser', { kind: 'cleaning' }, false);
function document(file, text) {
  return { file_name: file, source_path: `${directory}/${file}`, source_text: text,
    source_revision: createHash('sha256').update(text).digest('hex'), desired_revision: 'fixture-input',
    validation: { valid: true, messages: [] } };
}
const server = await createServer({ configFile: false, root: resolve(root, 'dashboard'),
  plugins: [tailwind(), { name: 'isolated-plugin-proof', configureServer(vite) {
    vite.middlewares.use(async (req, res, next) => {
      const url = new URL(req.url, 'http://fixture');
      if (url.pathname === '/') {
        res.setHeader('Content-Type', 'text/html');
        res.end(`<!doctype html><title>Plugin management proof</title><script type="module" src="/@vite/client"></script><script type="module" src="/@fs${evidence}/proof-client.ts"></script>`); return;
      }
      if (!url.pathname.startsWith('/api/')) return next();
      let body = ''; for await (const chunk of req) body += chunk;
      const input = body ? JSON.parse(body) : null;
      events.push({ method: req.method, path: url.pathname, input });
      let output;
      if (url.pathname === '/api/v1/lane-addons') output = snapshot;
      else if (url.pathname.endsWith('/package-catalog')) output = { directory: '/fixture/packages', parent: '/fixture', entries: [
        { kind: 'package', manifest_path: manifest, title: 'Fixture observation package', revision: '1.0.0', description: 'HTTP fixture package for installation flow' }] };
      else if (url.pathname.endsWith('/package-preview')) output = { manifest_path: manifest,
        package: { title: 'Fixture observation package', revision: '1.0.0', image: 'fixture:1', binding_schema: {
          type: 'object', additionalProperties: false, required: ['path'], properties: { path: { type: 'string', minLength: 1 } } } },
        image: { state: 'unverified', detail: 'Fixture does not inspect Docker' } };
      else if (url.pathname.endsWith('/declaration') && req.method === 'POST') {
        const data = getStaticTOMLValue(parseTOML(input.source_text));
        const doc = document(input.file_name, input.source_text); documents.set(doc.source_path, doc);
        const prior = snapshot.configuration.declarations.findIndex(item => item.source_path === doc.source_path);
        const declaration = { id: data.id, source_path: doc.source_path, enabled: data.enabled !== false,
          source_revision: doc.source_revision, desired_revision: 'fixture-input', applied_revision: null,
          instance_id: null, application: { kind: 'starting' } };
        if (prior < 0) snapshot.configuration.declarations.push(declaration);
        else snapshot.configuration.declarations[prior] = declaration;
        output = { document: doc, write: { state: 'created', durability: 'durable', detail: null }, application: 'pending_reconciliation' };
      } else if (url.pathname.endsWith('/declaration')) output = documents.get(url.searchParams.get('source_path'));
      else if (url.pathname.endsWith('/observe')) {
        const worker = snapshot.instances.find(item => item.instance_id === input.instance_id);
        if (!worker) throw new Error('Fixture worker missing');
        worker.observation_seq++; output = { instance_id: worker.instance_id, observation_seq: worker.observation_seq };
      } else if (url.pathname === '/api/proof-events') output = events;
      else { res.statusCode = 404; output = { error: 'Unsupported fixture route' }; }
      res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(output ?? { error: 'Fixture document missing' }));
    });
  } }], server: { host: '127.0.0.1', port: 0, fs: { allow: [root] } } });
await server.listen();
const address = server.httpServer.address();
const receipt = { url: `http://127.0.0.1:${address.port}`, pid: process.pid };
await writeFile('/private/tmp/plugin-management-proof-address.json', JSON.stringify(receipt));
console.log(receipt);
