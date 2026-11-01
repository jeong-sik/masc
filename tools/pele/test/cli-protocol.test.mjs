import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const executable = fileURLToPath(new URL('../render.mjs', import.meta.url));
const source = '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="16">'
  + '<rect width="32" height="16" fill="#19a974"/></svg>';
const request = { format: 'svg', source, maxWidth: 640 };
const env = { ...process.env, NODE_OPTIONS: '' };
const invoke = input => spawnSync(process.execPath, [executable], { input: JSON.stringify(input), env });
const receipt = Buffer.from('masc-pele-protocol:1\n');

test('ordinary CLI requests retain PNG stdout and no receipt', () => {
  const child = invoke(request);
  assert.equal(child.status, 0);
  assert.doesNotMatch(child.stderr.toString(), /^masc-pele-protocol:1$/m);
  assert.deepEqual([...child.stdout.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
});

test('protocol request confirms the renderer on success and on rendering failure', () => {
  const good = invoke({ ...request, protocol: 1 });
  assert.equal(good.status, 0);
  assert.doesNotMatch(good.stderr.toString(), /^masc-pele-protocol:1$/m);
  assert.deepEqual(good.stdout.subarray(0, receipt.length), receipt);
  assert.deepEqual([...good.stdout.subarray(receipt.length, receipt.length + 8)], [137, 80, 78, 71, 13, 10, 26, 10]);

  const bad = invoke({ ...request, protocol: 1, source: '<broken>' });
  assert.equal(bad.status, 1);
  assert.deepEqual(bad.stdout, receipt);
  assert.ok(bad.stderr.length > 0);
});

test('unknown protocol versions do not produce an image or a receipt', () => {
  for (const protocol of [0, 2, '1', null]) {
    const child = invoke({ ...request, protocol });
    assert.equal(child.status, 1);
    assert.equal(child.stdout.length, 0);
  }
});

test('startup diagnostics remain separate from the response frame', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pele-preload-'));
  try {
    const preload = join(directory, 'warning.cjs');
    writeFileSync(preload, "process.stderr.write('startup warning\\n');\n");
    const child = spawnSync(process.execPath, ['--require', preload, executable], {
      input: JSON.stringify({ ...request, protocol: 1 }),
      env,
    });
    assert.equal(child.status, 0);
    assert.match(child.stderr.toString(), /startup warning/);
    assert.doesNotMatch(child.stderr.toString(), /^masc-pele-protocol:1$/m);
    assert.deepEqual(child.stdout.subarray(0, receipt.length), receipt);
    assert.deepEqual([...child.stdout.subarray(receipt.length, receipt.length + 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
