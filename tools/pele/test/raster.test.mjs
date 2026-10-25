import { test } from 'node:test';
import assert from 'node:assert/strict';
import { inflateSync } from 'node:zlib';
import { spawnSync } from 'node:child_process';
import { DOMParser, XMLSerializer } from '@xmldom/xmldom';
import { Resvg } from '@resvg/resvg-js';
import { renderDocument } from '../engine.mjs';

const markup = (width, height, body, viewBox) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}"`
  + (viewBox === undefined ? '' : ` viewBox="${viewBox}"`) + `>${body}</svg>`;
const svg = markup(400, 200, '<rect width="400" height="200" fill="#19a974"/>');
const geometry = result => [result.png.readUInt32BE(16), result.png.readUInt32BE(20)];
const rootOf = result => new DOMParser().parseFromString(result.svg, 'image/svg+xml').documentElement;

// resvg emits RGBA8 PNGs. At the first pixel of the first scanline all filter
// neighbours are zero, so every PNG filter retains these four component bytes.
function firstPixel(png) {
  assert.equal(png[24], 8);
  assert.equal(png[25], 6);
  const chunks = [];
  for (let offset = 8; offset < png.length;) {
    const size = png.readUInt32BE(offset);
    if (png.toString('ascii', offset + 4, offset + 8) === 'IDAT') {
      chunks.push(png.subarray(offset + 8, offset + 8 + size));
    }
    offset += size + 12;
  }
  return [...inflateSync(Buffer.concat(chunks)).subarray(1, 5)];
}

test('explicit raster upscales vector detail while ordinary SVG retains its source and size', () => {
  const request = { format: 'svg', source: svg, maxWidth: 800 };
  const normal = renderDocument(request);
  assert.equal(normal.svg, svg);
  assert.deepEqual(geometry(normal), [400, 200]);
  const rendered = renderDocument({ ...request, raster: { width: 1200, height: 800 } });
  assert.deepEqual(geometry(rendered), [1200, 600]);
  assert.deepEqual([rendered.width, rendered.height], [400, 200]);
  assert.equal(rootOf(rendered).getAttribute('viewBox'), '0 0 400 200');
  assert.deepEqual(firstPixel(rendered.png), [25, 169, 116, 255]);
});

test('normalized crop corners retain original nonzero SVG coordinates and visible content', () => {
  const source = markup(400, 200,
    '<rect x="-100" y="50" width="200" height="200" fill="#0000ff"/>'
    + '<rect x="100" y="50" width="200" height="200" fill="#ff0000"/>',
    '-100 50 400 200');
  const rendered = renderDocument({ format: 'svg', source, maxWidth: 100,
    raster: { width: 80, height: 40, crop: { left: 0.5, top: 0, right: 1, bottom: 1 } } });
  assert.equal(rootOf(rendered).getAttribute('viewBox'), '200 0 200 200');
  assert.equal(rootOf(rendered).firstChild.getAttribute('viewBox'), '-100 50 400 200');
  assert.deepEqual(geometry(rendered), [40, 40]);
  assert.deepEqual([rendered.width, rendered.height], [400, 200]);
  assert.deepEqual(firstPixel(rendered.png), [255, 0, 0, 255]);

  const intrinsic = renderDocument({ format: 'svg',
    source: markup(400, 200, '<rect x="200" width="200" height="200" fill="#ff0000"/>'),
    maxWidth: 100, raster: { width: 80, height: 40,
      crop: { left: 0.5, top: 0, right: 1, bottom: 1 } } });
  assert.equal(rootOf(intrinsic).getAttribute('viewBox'), '200 0 200 200');
  assert.deepEqual(firstPixel(intrinsic.png), [255, 0, 0, 255]);
});

test('raster windows retain authored viewport aspect mapping and nonzero viewBox origins', () => {
  for (const [mode, expected] of [[undefined, [0, 0, 0, 0]],
    ['none', [0, 0, 255, 255]], ['xMidYMid slice', [255, 0, 0, 255]]]) {
    const source = '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="200"'
      + ' viewBox="-50 20 100 100"'
      + (mode === undefined ? '' : ` preserveAspectRatio="${mode}"`) + '>'
      + '<rect x="-50" y="20" width="100" height="100" fill="#ff0000"/>'
      + '<rect x="-50" y="20" width="100" height="25" fill="#0000ff"/></svg>';
    const request = { format: 'svg', source, maxWidth: 800 };
    const normal = renderDocument(request);
    assert.deepEqual(geometry(normal), [400, 200]);
    assert.deepEqual(firstPixel(normal.png), expected);
    const full = renderDocument({ ...request, raster: { width: 800, height: 400 } });
    assert.deepEqual(geometry(full), [800, 400]);
    assert.deepEqual([full.width, full.height], [400, 200]);
    assert.deepEqual(firstPixel(full.png), expected);
    assert.equal(rootOf(full).firstChild.getAttribute('viewBox'), '-50 20 100 100');
    assert.equal(rootOf(full).firstChild.getAttribute('preserveAspectRatio'), mode ?? null);
    const cropped = renderDocument({ ...request, raster: { width: 200, height: 200,
      crop: { left: 0, top: 0, right: 0.5, bottom: 0.25 } } });
    assert.deepEqual(geometry(cropped), [200, 50]);
    assert.deepEqual(firstPixel(cropped.png), expected);
  }
});

test('cropping preserves percentage lengths in the original SVG viewport', () => {
  const result = renderDocument({ format: 'svg', maxWidth: 800,
    source: markup(400, 200,
      '<rect width="100%" height="100%" fill="#ff0000"/>'
      + '<rect width="50%" height="100%" fill="#0000ff"/>'),
    raster: { width: 100, height: 100,
      crop: { left: 0.25, top: 0, right: 0.75, bottom: 1 } } });
  assert.deepEqual(geometry(result), [100, 100]);
  assert.deepEqual(firstPixel(result.png), [0, 0, 255, 255]);
  const original = rootOf(result).firstChild;
  assert.equal(original.getAttribute('viewBox'), '0 0 400 200');
  assert.equal(original.getAttribute('width'), '400');
});

test('materializing supported CSS before nesting retains original selector matches and pixels', () => {
  const source = markup(400, 200, '<style>svg svg rect {fill:red;}</style>'
    + '<rect width="400" height="200"/>'
    + '<svg x="200" width="200" height="200"><rect width="200" height="200"/></svg>');
  const request = { format: 'svg', source, maxWidth: 800 };
  const normal = renderDocument(request);
  const full = renderDocument({ ...request, raster: { width: 400, height: 200 } });
  assert.deepEqual(full.png, normal.png);
  assert.deepEqual(firstPixel(full.png), [0, 0, 0, 255]);
  const crop = renderDocument({ ...request, raster: { width: 80, height: 40,
    crop: { left: 0.5, top: 0, right: 1, bottom: 1 } } });
  assert.deepEqual(firstPixel(crop.png), [255, 0, 0, 255]);
});

test('Mermaid font size is a frozen layout input independent of raster dimensions and crop', () => {
  const request = { format: 'mermaid', source: 'flowchart LR\n A[계정 확인] --> B[완료]',
    maxWidth: 640, fontSize: 24,
    colors: { foreground: '#cdd6f4', background: '#1e1e2e' } };
  const normal = renderDocument(request);
  const enlarged = renderDocument({ ...request, raster: { width: 1920, height: 1080,
    crop: { left: 0.25, top: 0.25, right: 0.75, bottom: 0.75 } } });
  assert.deepEqual([enlarged.width, enlarged.height], [normal.width, normal.height]);
  const children = root => Array.from(root.childNodes)
    .map(node => new XMLSerializer().serializeToString(node)).join('');
  const canonical = rootOf({ svg: new Resvg(normal.svg).toString() });
  assert.equal(children(rootOf(enlarged).firstChild), children(canonical));
  assert.ok(enlarged.png.readUInt32BE(16) <= 1920);
  assert.ok(enlarged.png.readUInt32BE(20) <= 1080);
  const smaller = renderDocument({ ...request, fontSize: 16,
    raster: { width: 16, height: 16 } });
  assert.notDeepEqual([smaller.width, smaller.height], [normal.width, normal.height]);
});

test('wide, tall, narrow and deeply zoomed sources allocate only a bounded visible raster', () => {
  for (const [width, height, expected] of [[1000000, 1, [640, 1]],
    [1, 1000000, [1, 400]], [480, 212, [640, 282]], [1, 1, [400, 400]]]) {
    const result = renderDocument({ format: 'svg',
      source: markup(width, height, `<rect width="${width}" height="${height}" fill="#19a974"/>`),
      maxWidth: 800, raster: { width: 640, height: 400 } });
    assert.deepEqual(geometry(result), expected);
  }
  const result = renderDocument({ format: 'svg',
    source: markup(1000000, 1000000, '<rect width="1000000" height="1000000" fill="#19a974"/>'),
    maxWidth: 800, raster: { width: 64, height: 32,
      crop: { left: 0.5, top: 0.5, right: 0.500001, bottom: 0.500001 } } });
  assert.deepEqual(geometry(result), [32, 32]);
  assert.deepEqual([result.width, result.height], [1000000, 1000000]);
  assert.deepEqual(firstPixel(result.png), [25, 169, 116, 255]);
});

test('invalid raster/font requests fail explicitly and raster mode retains external-source refusal', () => {
  const request = { format: 'svg', source: svg, maxWidth: 800 };
  for (const fontSize of [null, 0, -1, 1.5, Infinity, '16', Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => renderDocument({ ...request, fontSize }), /fontSize/);
  }
  for (const raster of [null, [], {}, { width: 0, height: 10 },
    { width: 10, height: Infinity }, { width: '10', height: 10 },
    { width: Number.MAX_SAFE_INTEGER + 1, height: 10 },
    ...[null, [], {}, { left: 0, top: 0, right: 0, bottom: 1 },
      { left: -0.01, top: 0, right: 1, bottom: 1 },
      { left: 0, top: 0.9, right: 1, bottom: 0.1 },
      { left: 0, top: 0, right: 1.01, bottom: 1 },
      { left: 0, top: 0, right: NaN, bottom: 1 },
      { left: 0, top: 0, right: 1, bottom: Infinity }]
      .map(crop => ({ width: 20, height: 20, crop }))]) {
    assert.throws(() => renderDocument({ ...request, raster }), /raster/);
  }
  assert.throws(() => renderDocument({ ...request,
    source: markup(400, 200, '<image href="file:///not-opened.png"/>'),
    raster: { width: 20, height: 20 } }), /unavailable/);
});

test('JSON CLI accepts a raster window and rejects malformed crops without image bytes', () => {
  const request = { format: 'svg', source: svg, maxWidth: 800, fontSize: 24,
    raster: { width: 40, height: 20,
      crop: { left: 0.25, top: 0.25, right: 0.75, bottom: 0.75 } } };
  const invoke = input => spawnSync(process.execPath, ['tools/pele/render.mjs'],
    { input: JSON.stringify(input), cwd: new URL('../../..', import.meta.url) });
  const accepted = invoke(request);
  assert.equal(accepted.status, 0, accepted.stderr.toString());
  assert.deepEqual(geometry({ png: accepted.stdout }), [40, 20]);
  const rejected = invoke({ ...request,
    raster: { ...request.raster, crop: { left: 1, top: 0, right: 0, bottom: 1 } } });
  assert.equal(rejected.status, 1);
  assert.equal(rejected.stdout.length, 0);
  assert.match(rejected.stderr.toString(), /raster\.crop/);
});
