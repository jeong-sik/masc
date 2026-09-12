import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { PNG } from 'pngjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const proof = resolve('proof');
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

// This verifier reads returned evidence independently; it does not import the
// package's counter parser, pixel matcher, or its self-reported success fields.
async function verifyOutput(output, expected, label) {
  const artifacts = new Map(output.artifacts.map(artifact => [artifact.id, artifact]));
  const bytes = id => Buffer.from(artifacts.get(id).data_base64, 'base64');
  const state = bytes('state');
  assert.deepEqual([...state.subarray(0, 6)], [76, 65, 78, 69, 1, 0]);
  assert.equal(state.length, 8);
  assert.equal(state[6] + 256 * state[7], expected);
  const png = PNG.sync.read(bytes('frame'));
  assert.equal(png.width, 320);
  assert.equal(png.height, 200);
  const greenPositions = [], whitePositions = [];
  for (let pixel = 0; pixel < png.width * png.height; pixel++) {
    const [r, g, b, alpha] = png.data.subarray(pixel * 4, pixel * 4 + 4);
    assert.equal(alpha, 255);
    if (r === 0 && g === 0 && b === 0) continue;
    if (r === 0 && g > 0 && b === 0) greenPositions.push(pixel);
    else {
      assert.ok(r > 0 && r === g && g === b, 'only the guest palette is present');
      whitePositions.push(pixel);
    }
  }
  const rectangle = (x, y, width, height) => Array.from({ length: height }, (_, row) =>
    Array.from({ length: width }, (_, column) => (y + row) * 320 + x + column)).flat();
  assert.deepEqual(greenPositions, rectangle(16, 80, 1 + expected % 256, 16));
  assert.deepEqual(whitePositions, rectangle(16, 32, 288, 16));
  const row = output.rows[0];
  assert.equal(row.fields.counter, expected);
  assert.equal(row.clock.value, String(row.fields.capture_sequence));
  assert.ok(row.clock.domain.endsWith('/capture'));
  assert.equal(Object.hasOwn(row.fields, 'frame'), false, 'capture count is not an emulated frame');
  assert.equal(output.coverage[0].complete, true);
  assert.deepEqual(row.evidence.map(ref => ref.artifact_id).sort(), ['build', 'frame', 'state']);
  await Promise.all([
    writeFile(join(proof, `${label}.png`), bytes('frame')),
    writeFile(join(proof, `${label}.STATE.BIN`), state),
    writeFile(join(proof, `${label}.output.json`), JSON.stringify(output, null, 2)),
    writeFile(join(proof, 'BUILD_SHA256SUMS'), bytes('build'))]);
  return { label, counter: expected, frame_sha256: digest(bytes('frame')), state_sha256: digest(state),
    capture_sequence: row.fields.capture_sequence };
}

test('real DOS input, receipts, read-only observation, incarnation and independent artifacts', { timeout: 120_000 }, async t => {
  await mkdir(proof, { recursive: true });
  const transport = new StdioClientTransport({ command: process.execPath,
    args: [join(root, 'server.mjs')], cwd: root, stderr: 'pipe' });
  const client = new Client({ name: 'dos-world-independent-verifier', version: '0.1.0' });
  let stderr = '';
  transport.stderr.on('data', bytes => { stderr += bytes.toString(); });
  t.after(async () => {
    await client.close();
    await writeFile(join(proof, 'server.stderr.log'), stderr);
    for (const line of stderr.split('\n')) {
      let diagnostic;
      try { diagnostic = JSON.parse(line); } catch { continue; }
      if (diagnostic.event !== 'dos_shutdown') continue;
      await writeFile(join(proof, 'shutdown-diagnostics.json'), JSON.stringify(diagnostic, null, 2));
      if (diagnostic.capture !== null) await writeFile(join(proof, 'unverified-capture.png'),
        Buffer.from(diagnostic.capture.png_base64, 'base64'));
      if (diagnostic.state_base64 !== null) await writeFile(join(proof, 'unverified-STATE.BIN'),
        Buffer.from(diagnostic.state_base64, 'base64'));
    }
  });
  await client.connect(transport);
  const tools = await client.listTools();
  assert.deepEqual(tools.tools.map(tool => tool.name).sort(), ['lane_act', 'lane_observe']);
  const context = { instance_id: 'ci-dos-instance', incarnation: 'ci-dos-instance' };
  async function call(name, args) {
    const response = await client.callTool({ name, arguments: args }, undefined, { signal: t.signal });
    assert.notEqual(response.isError, true, JSON.stringify(response));
    assert.ok(response.structuredContent);
    return response.structuredContent;
  }
  const observe = () => call('lane_observe', { context, binding: { sources: [] }, sources: [] });
  const act = request_id => call('lane_act', { context, request_id, action: { kind: 'increment' } });
  // One initial observation must publish verified data on an otherwise idle
  // world. No timer/polling or unrelated activity is used to finish startup.
  const initial = await observe();
  const measurements = [await verifyOutput(initial, 0, 'before')];
  await verifyOutput(await observe(), 0, 'observe-only');
  const [first, crossed] = await Promise.all([act('increment-once'), observe()]);
  // A valid fast action may complete before the observation is serviced. This
  // real-environment proof permits either snapshot and checks its actual pixels;
  // it does not manufacture a slow action to force a particular response order.
  const crossedState = Buffer.from(crossed.artifacts.find(artifact => artifact.id === 'state').data_base64, 'base64');
  const crossedCounter = crossedState.readUInt16LE(6);
  assert.ok(crossedCounter === 0 || crossedCounter === 1);
  await verifyOutput(crossed, crossedCounter, 'overlapping-observe');
  assert.equal(first.status, 'confirmed');
  assert.equal(first.result.confirmation, 'guest_file_and_matching_bar_pixels');
  assert.equal(first.result.before_counter, 0);
  assert.equal(first.result.after_counter, 1);
  measurements.push(await verifyOutput(first.output, 1, 'after'));
  assert.deepEqual(await act('increment-once'), first, 'duplicate request returns the same receipt');
  await verifyOutput(await observe(), 1, 'after-duplicate');

  const stale = await call('lane_act', { context: { instance_id: 'old-instance', incarnation: 'old-instance' },
    request_id: 'stale', action: { kind: 'increment' } });
  assert.equal(stale.status, 'failed_before_effect');
  await verifyOutput(await observe(), 1, 'after-stale');
  const invalid = await call('lane_act', { context, request_id: 'invalid', action: { kind: 'reset' } });
  assert.equal(invalid.status, 'failed_before_effect');
  await verifyOutput(await observe(), 1, 'after-invalid');

  const [second, duplicate] = await Promise.all([act('overlap'), act('overlap')]);
  assert.equal(second.status, 'confirmed');
  assert.deepEqual(second, duplicate, 'overlapping duplicate calls share one action');
  measurements.push(await verifyOutput(second.output, 2, 'overlap'));
  await verifyOutput(await observe(), 2, 'final-observe');
  const program = await readFile(join(root, 'guest/LANEDEMO.COM'));
  assert.equal(initial.rows[0].fields.program_sha256, digest(program));
  await writeFile(join(proof, 'receipts.json'), JSON.stringify({ first, stale, invalid, second }, null, 2));
  await writeFile(join(proof, 'measurements.json'), JSON.stringify({
    scope: 'Package MCP + real DOS/WASM + independent guest-file/pixel verification; no MASC host or Keeper proof',
    engine: 'emulators@8.4.2', program_sha256: digest(program), measurements }, null, 2));
});
