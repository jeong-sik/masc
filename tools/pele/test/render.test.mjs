import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { renderDocument } from '../engine.mjs';

const flow = 'flowchart LR\n A[안녕하세요] --> B[저장] --> C[확인]';

test('real Pele and resvg render diagram families the text canvas cannot draw', () => {
  for (const source of [flow,
    'sequenceDiagram\n Alice->>Bob: Hello',
    'classDiagram\n Animal <|-- Duck',
    'pie title Work\n "Done": 8\n "Pending": 2',
    'xychart-beta\n x-axis [Jan, Feb, Mar]\n bar [2, 4, 3]',
    'mindmap\n root((MASC))\n  Keeper\n  Board',
  ]) {
    const result = renderDocument({ format: 'mermaid', source, maxWidth: 640 });
    assert.deepEqual([...result.png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
    assert.ok(result.png.readUInt32BE(16) <= 640);
    assert.ok(result.png.readUInt32BE(20) > 0);
    assert.ok(!result.svg.includes('var(--'));
  }
});

test('terminal width reaches Pele responsive layout and labels survive theme resolution', () => {
  const wide = renderDocument({ format: 'mermaid', source: flow, maxWidth: 1200 });
  const narrow = renderDocument({ format: 'mermaid', source: flow, maxWidth: 320,
    colors: { foreground: '#eeeeee', background: '#161616' } });
  assert.ok(narrow.width < wide.width);
  assert.ok(narrow.height > wide.height);
  assert.ok(narrow.svg.includes('안녕하세요'));
  assert.ok(narrow.svg.includes('fill="#161616"'));
  assert.ok(narrow.svg.includes('stroke="#eeeeee"'));
  assert.ok(narrow.png.readUInt32BE(16) <= 320);
  const label = renderDocument({ format: 'mermaid', source: 'flowchart TD\n A["var(--keep-me) <script>alert(1)</script>"]', maxWidth: 640 });
  assert.ok(label.svg.includes('var(--keep-me)'));
  assert.ok(!label.svg.includes('<script>'));
});

test('bad source and invalid requests fail without emitting an image', () => {
  for (const request of [{ format: 'mermaid', source: 'not a diagram', maxWidth: 640 },
    { format: 'mermaid', source: flow, maxWidth: -1 },
    { format: 'mermaid', source: flow, maxWidth: 640, colors: { foreground: 'url(file:///etc/passwd)' } },
  ]) {
    const child = spawnSync(process.execPath, ['tools/pele/render.mjs'],
      { input: JSON.stringify(request), cwd: new URL('../../..', import.meta.url) });
    assert.equal(child.status, 1);
    assert.equal(child.stdout.length, 0);
    assert.ok(child.stderr.length > 0);
  }
});

test('diagram image URLs are never fetched or exposed to the rasterizer', () => {
  const source = 'flowchart TD\n A@{ img: "file:///etc/passwd", label: "external" }';
  const result = renderDocument({ format: 'mermaid', source, maxWidth: 640 });
  assert.ok(!result.svg.includes('<image'));
  assert.ok(!result.svg.includes('file:///etc/passwd'));
});

test('literal chart labels in metadata are not CSS variables', () => {
  const result = renderDocument({ format: 'mermaid', source: 'pie\n "var(--foo)":10', maxWidth: 640 });
  assert.ok(result.svg.includes('data-id="var(--foo)"'));
  assert.ok(result.png.length > 0);
});

test('parser diagnostics escape terminal controls embedded in source', () => {
  const child = spawnSync(process.execPath, ['tools/pele/render.mjs'], {
    input: JSON.stringify({ format: 'mermaid', source: 'flowchart TD\n A --> \u001b]0;OWNED\u0007', maxWidth: 640 }),
    cwd: new URL('../../..', import.meta.url),
  });
  assert.equal(child.status, 1);
  assert.equal(child.stdout.length, 0);
  assert.ok(!/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/.test(child.stderr.toString()));
});
