import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PNG } from 'pngjs';

const require = createRequire(import.meta.url);
const root = dirname(fileURLToPath(import.meta.url));
const pendingState = Buffer.from('PEND0000');
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const text = { type: 'string', minLength: 1 };
const contextSchema = { type: 'object', additionalProperties: false,
  required: ['instance_id', 'incarnation'],
  properties: { instance_id: text, incarnation: text } };
export const actionSchema = { type: 'object', additionalProperties: false,
  required: ['context', 'request_id', 'action'], properties: {
    context: contextSchema, request_id: text,
    action: { type: 'object', additionalProperties: false, required: ['kind'],
      properties: { kind: { type: 'string', enum: ['increment'] } } } } };
export const observeSchema = { type: 'object', additionalProperties: false,
  required: ['context', 'binding', 'sources'], properties: {
    context: contextSchema, binding: { type: 'object', additionalProperties: false,
      required: ['sources'], properties: { sources: { type: 'array', maxItems: 0 } } },
    sources: { type: 'array', maxItems: 0 } } };

function exactObject(value, keys, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).length !== keys.length || keys.some(key => !Object.hasOwn(value, key))) {
    throw new Error(`${label} requires exactly: ${keys.join(', ')}`);
  }
}
function parseContext(context) {
  exactObject(context, ['instance_id', 'incarnation'], 'context');
  for (const value of Object.values(context)) {
    if (typeof value !== 'string' || value.trim().length === 0) throw new Error('context identifiers must be nonblank strings');
  }
  // This first host protocol gives each worker one machine, with no in-place reset.
  if (context.instance_id !== context.incarnation) throw new Error('incarnation must identify this host instance');
  return Object.freeze({ ...context });
}

function counterOf(bytes) {
  if (bytes.equals(pendingState)) return null;
  if (bytes.length !== 8 || bytes.subarray(0, 4).toString('ascii') !== 'LANE' || bytes.readUInt16LE(4) !== 1) {
    throw new Error('STATE.BIN does not match the guest format');
  }
  return bytes.readUInt16LE(6);
}

// Exact geometry of the guest's VGA output. Palette intensity is backend-specific;
// colour channels and the black background identify the actual green/white pixels.
function matchesGuest(frame, counter) {
  if (frame.width !== 320 || frame.height !== 200) return false;
  const barWidth = 1 + counter % 256;
  for (let y = 0; y < frame.height; y++) {
    for (let x = 0; x < frame.width; x++) {
      const i = (y * frame.width + x) * 4;
      const [r, g, b] = frame.rgba.subarray(i, i + 3);
      if (y >= 32 && y < 48 && x >= 16 && x < 304) {
        if (!(r > 0 && r === g && g === b)) return false;
      } else if (y >= 80 && y < 96 && x >= 16 && x < 16 + barWidth) {
        if (!(r === 0 && g > 0 && b === 0)) return false;
      } else if (r !== 0 || g !== 0 || b !== 0) return false;
    }
  }
  return true;
}

export class DosWorld {
  context = null;
  ci = null;
  boot = null;
  failure = null;
  closed = false;
  latestFrame = null;
  lastGuestBytes = null;
  snapshot = null;
  captureSequence = 0;
  probing = false;
  waiters = new Set();
  receipts = new Map();
  actionTail = Promise.resolve();
  closePromise = null;

  bind(raw) {
    const context = parseContext(raw);
    if (this.context !== null && (this.context.instance_id !== context.instance_id
        || this.context.incarnation !== context.incarnation)) throw new Error('request targets a different machine incarnation');
    if (this.closed) throw new Error('machine owner has closed');
    if (this.context === null) {
      this.context = context;
      this.boot = this.start().catch(error => this.fail(error));
    }
  }

  fail(error) {
    this.failure = error instanceof Error ? error.message : String(error);
    this.notify();
  }

  notify() {
    for (const wake of this.waiters) wake();
    this.waiters.clear();
  }

  async start() {
    // The official Node API installs globalThis.emulators. Its WASM assets are
    // loaded from the pinned npm package, never from a runtime CDN.
    require('emulators');
    const emulators = globalThis.emulators;
    emulators.pathPrefix = dirname(require.resolve('emulators')) + '/';
    // js-dos screenshot's only browser dependency; Node receives byte buffers.
    globalThis.ImageData ??= class {
      constructor(data, width, height) { Object.assign(this, { data, width, height }); }
    };
    const [program, config, hashes] = await Promise.all([
      readFile(join(root, 'guest/LANEDEMO.COM')),
      readFile(join(root, 'environment/dosbox.conf'), 'utf8'),
      readFile(join(root, 'BUILD_SHA256SUMS'), 'utf8')]);
    this.buildHashes = hashes;
    this.programSha256 = sha256(program);
    this.ci = await emulators.dosboxNode([
      { dosboxConf: config, jsdosConf: { version: emulators.version } },
      { path: 'LANEDEMO.COM', contents: new Uint8Array(program) },
      { path: 'STATE.BIN', contents: new Uint8Array(pendingState) }]);
    const events = this.ci.events();
    events.onMessage((kind, ...details) => {
      // Engine diagnostics must never corrupt MCP stdout.
      // Diagnostic severity is not machine lifecycle: even ordinary DOS
      // execution messages can use the error channel. Startup rejection and
      // onExit below report actual environment failure.
      console.error(JSON.stringify({ engine_message: kind, details }));
    });
    events.onExit(() => this.fail(new Error('DOS machine exited')));
    events.onFrame((rgb, rgba) => {
      const width = this.ci.width(), height = this.ci.height();
      const pixels = Buffer.alloc(width * height * 4);
      const bytes = rgb ?? rgba;
      if (bytes === null) return;
      const stride = rgb === null ? 4 : 3;
      for (let pixel = 0; pixel < width * height; pixel++) {
        pixels[pixel * 4] = bytes[pixel * stride];
        pixels[pixel * 4 + 1] = bytes[pixel * stride + 1];
        pixels[pixel * 4 + 2] = bytes[pixel * stride + 2];
        pixels[pixel * 4 + 3] = 255;
      }
      this.capture(width, height, pixels);
    });
    // A frame can arrive during engine startup before consumer registration.
    if (this.ci.width() > 0 && this.ci.height() > 0) {
      const frame = await this.ci.screenshot();
      this.capture(frame.width, frame.height, Buffer.from(frame.data));
    }
  }

  capture(width, height, rgba) {
    this.latestFrame = { width, height, rgba, sequence: ++this.captureSequence,
      observedAt: Date.now() / 1000 };
    void this.probe();
  }

  async probe() {
    if (this.probing || this.failure !== null || this.closed) return;
    this.probing = true;
    try {
      let examined;
      do {
        const frame = this.latestFrame;
        examined = frame.sequence;
        // Serial reads: js-dos does not allow simultaneous reads of one file.
        const state = Buffer.from(await this.ci.fsReadFile('STATE.BIN'));
        this.lastGuestBytes = state;
        const counter = counterOf(state);
        if (counter !== null && matchesGuest(frame, counter)) {
          this.snapshot = { frame, state, counter };
          this.notify();
        }
      } while (!this.closed && this.latestFrame.sequence !== examined);
    } catch (error) {
      this.fail(error);
    } finally {
      this.probing = false;
    }
  }

  async untilSnapshot(predicate) {
    for (;;) {
      if (this.failure !== null || this.closed) throw new Error(this.failure ?? 'machine owner has closed');
      if (this.snapshot !== null && predicate(this.snapshot)) return this.snapshot;
      await new Promise(resolve => this.waiters.add(resolve));
    }
  }

  output(snapshot = this.snapshot) {
    const source = this.context === null ? 'dos/unbound' : `dos/${this.context.instance_id}`;
    const incarnation = this.context?.incarnation ?? 'unbound';
    const complete = snapshot !== null && this.failure === null && !this.closed;
    const coverage = [{ source_id: source, incarnation,
      cursor: snapshot === null ? null : String(snapshot.frame.sequence), complete,
      detail: this.failure ?? (this.closed ? 'Machine owner closed' : snapshot === null
        ? 'Waiting for the guest state file and matching rendered pixels'
        : 'Latest verified capture only; intermediate frames are coalesced, not an exhaustive frame history') }];
    if (snapshot === null) return { rows: [], coverage, artifacts: [] };
    const { frame, state, counter } = snapshot;
    const image = PNG.sync.write({ width: frame.width, height: frame.height, data: frame.rgba });
    return { coverage, rows: [{
      id: `capture-${frame.sequence}`, lane_id: 'dos/guest', kind: 'value',
      title: `DOS guest counter ${counter}`, observed_at: frame.observedAt,
      subject_id: source, actor: null,
      clock: { domain: `${source}/${incarnation}/capture`, value: String(frame.sequence) },
      fields: { machine_incarnation: incarnation, capture_sequence: frame.sequence,
        counter, counter_semantics: 'guest uint16 increment count modulo 65536',
        bar_width: 1 + counter % 256, width: frame.width, height: frame.height,
        program_sha256: this.programSha256, engine: 'emulators', engine_version: '8.4.2' },
      evidence: [{ artifact_id: 'frame' }, { artifact_id: 'state' }, { artifact_id: 'build' }],
      related_ids: [] }], artifacts: [
      { id: 'frame', mime_type: 'image/png', data_base64: image.toString('base64') },
      { id: 'state', mime_type: 'application/octet-stream', data_base64: state.toString('base64') },
      { id: 'build', mime_type: 'text/plain', data_base64: Buffer.from(this.buildHashes).toString('base64') }] };
  }

  async observe(args) {
    exactObject(args, ['context', 'binding', 'sources'], 'observe arguments');
    exactObject(args.binding, ['sources'], 'binding');
    if (!Array.isArray(args.sources) || args.sources.length !== 0
      || !Array.isArray(args.binding.sources) || args.binding.sources.length !== 0) {
      throw new Error('This package owns its DOS environment and takes no external observation sources');
    }
    this.bind(args.context);
    // Complete the attach-triggered observation without relying on unrelated
    // world activity to wake the host after our own machine boots. This wait is
    // local to this optional worker and ends on actual state/pixels or failure.
    if (this.snapshot === null) await this.untilSnapshot(() => true);
    return this.output();
  }

  act(args) {
    try {
      exactObject(args, ['context', 'request_id', 'action'], 'action arguments');
      exactObject(args.action, ['kind'], 'action');
      if (args.action.kind !== 'increment') throw new Error('Unknown action kind');
      if (typeof args.request_id !== 'string' || args.request_id.trim().length === 0) throw new Error('request_id must be nonblank');
      this.bind(args.context);
    } catch (error) {
      return Promise.resolve({ status: 'failed_before_effect', result: { reason: error.message }, output: this.output() });
    }
    // The host owns durable receipt storage. This extra cache prevents duplicate
    // input during this worker lifetime, including overlapping MCP requests.
    const key = JSON.stringify([args.context.instance_id, args.context.incarnation, args.request_id]);
    const previous = this.receipts.get(key);
    if (previous !== undefined) return previous;
    const receipt = this.actionTail.then(async () => {
      let inputStarted = false;
      try {
        const before = await this.untilSnapshot(() => true);
        const expected = (before.counter + 1) % 65536;
        inputStarted = true;
        // js-dos Keys.KBD_n uses the uppercase Latin key-code range (78),
        // independent of the lower/uppercase character emitted by the guest.
        this.ci.simulateKeyPress('N'.charCodeAt(0));
        const after = await this.untilSnapshot(snapshot => snapshot.frame.sequence > before.frame.sequence
          && snapshot.counter !== before.counter);
        if (after.counter !== expected) throw new Error('Observed guest counter differs from the requested increment');
        return { status: 'confirmed', result: { confirmation: 'guest_file_and_matching_bar_pixels',
          instance_id: this.context.instance_id, incarnation: this.context.incarnation,
          request_id: args.request_id, before_counter: before.counter, after_counter: after.counter,
          capture_sequence: after.frame.sequence }, output: this.output(after) };
      } catch (error) {
        return { status: inputStarted ? 'outcome_unknown' : 'failed_before_effect',
          result: { reason: error.message, request_id: args.request_id }, output: this.output() };
      }
    });
    this.receipts.set(key, receipt);
    this.actionTail = receipt.then(() => undefined);
    return receipt;
  }

  close() {
    if (this.closePromise !== null) return this.closePromise;
    this.closed = true;
    this.notify();
    // Preserve actual unverified captures on shutdown as diagnostics. This does
    // not promote them to a Lane observation or claim successful guest output.
    const frame = this.latestFrame;
    console.error(JSON.stringify({ event: 'dos_shutdown', failure: this.failure,
      verified_counter: this.snapshot?.counter ?? null, probe_pending: this.probing,
      capture: frame === null ? null : { width: frame.width, height: frame.height,
        sequence: frame.sequence, png_base64: PNG.sync.write({ width: frame.width,
          height: frame.height, data: frame.rgba }).toString('base64') },
      state_base64: this.lastGuestBytes?.toString('base64') ?? null }));
    this.closePromise = (async () => {
      await this.boot;
      if (this.ci !== null) await this.ci.exit();
    })();
    return this.closePromise;
  }
}
