import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { DOMParser } from '@xmldom/xmldom';
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
  assert.ok(narrow.svg.includes('stroke="#eeeeee"'));
  assert.ok(narrow.png.readUInt32BE(16) <= 320);
  const label = renderDocument({ format: 'mermaid', source: 'flowchart TD\n A["var(--keep-me) <script>alert(1)</script>"]', maxWidth: 640 });
  assert.ok(label.svg.includes('var(--keep-me)'));
  assert.ok(!label.svg.includes('<script>'));
});

test('authored node, group and edge styles survive both terminal palettes', () => {
  const source = `flowchart LR
 subgraph work[Work]
 A[Pending]:::pending --> B([Done])
 end
 classDef pending fill:#dbeafe,stroke:#2563eb,color:#172554
 style B fill:#dcfce7,stroke:#16a34a,color:#052e16
 style work fill:#e0e7ff,stroke:#818cf8,color:#1e1b4b
 linkStyle 0 stroke:#d97706,stroke-width:3px,stroke-dasharray:4 4`;
  for (const colors of [
    { foreground: '#cdd6f4', background: '#1e1e2e' },
    { foreground: '#243247', background: '#f8fafc' },
  ]) {
    const result = renderDocument({ format: 'mermaid', source, maxWidth: 1200, colors });
    const document = new DOMParser().parseFromString(result.svg, 'image/svg+xml');
    const elements = Array.from(document.getElementsByTagName('*'));
    const owned = id => elements.find(element => element.getAttribute('data-id') === id).toString();
    assert.ok(owned('A').includes('fill:#dbeafe'));
    assert.ok(owned('A').includes('stroke:#2563eb'));
    assert.ok(owned('A').includes('fill:#172554'));
    assert.ok(owned('B').includes('fill:#dcfce7'));
    assert.ok(owned('B').includes('fill:#052e16'));
    assert.ok(owned('work').includes('fill:#e0e7ff'));
    assert.ok(owned('work').includes('fill:#1e1b4b'));
    assert.ok(owned('L_A_B_0').includes('stroke:#d97706'));
    assert.ok(owned('L_A_B_0').includes('stroke-dasharray:4 4'));
    assert.ok(result.png.length > 0);
  }
});

test('default surfaces retain readable text and boundaries across observed palettes', () => {
  const source = 'flowchart LR\n subgraph work[Work]\n A[Plain] --> B[Next]\n end';
  // WCAG relative luminance and contrast, applied to resolved SVG colours.
  const luminance = hex => {
    const channels = hex.slice(1).match(/../g).map(value => Number.parseInt(value, 16) / 255)
      .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
    return channels.reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
  };
  const contrast = (a, b) => {
    const values = [luminance(a), luminance(b)].sort((x, y) => x - y);
    return (values[1] + 0.05) / (values[0] + 0.05);
  };
  for (const colors of [
    { foreground: '#cdd6f4', background: '#1e1e2e' },
    { foreground: '#243247', background: '#f8fafc' },
    { foreground: '#777777', background: '#000000' },
    { foreground: '#767676', background: '#ffffff' },
  ]) {
    const result = renderDocument({ format: 'mermaid', source, maxWidth: 1200, colors });
    const document = new DOMParser().parseFromString(result.svg, 'image/svg+xml');
    const elements = Array.from(document.getElementsByTagName('*'));
    const owned = id => elements.find(element => element.getAttribute('data-id') === id);
    const node = owned('A').getElementsByTagName('rect')[0];
    const group = owned('work').getElementsByTagName('rect')[0];
    const heading = owned('work').getElementsByTagName('text')[0];
    for (const fill of [colors.background, node.getAttribute('fill'), group.getAttribute('fill')]) {
      assert.ok(contrast(colors.foreground, fill) >= 4.5);
      assert.ok(contrast(heading.getAttribute('fill'), fill) >= 4.5);
      assert.ok(contrast(node.getAttribute('stroke'), fill) >= 3);
    }
    assert.ok(!result.svg.includes('var(--'));
  }
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
