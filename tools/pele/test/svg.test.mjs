import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { renderDocument } from '../engine.mjs';

const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="200" viewBox="0 0 400 200">'
  + '<defs><rect id="bar" width="100" height="200" fill="#19a974"/></defs>'
  + '<use href="#bar"/><rect x="100" width="300" height="200" fill="#eb5757"/></svg>';

function geometry(png) {
  assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  return [png.readUInt32BE(16), png.readUInt32BE(20)];
}

test('retained SVG uses real resvg, internal references and aspect-preserving downscale', () => {
  const result = renderDocument({ format: 'svg', source: svg, maxWidth: 100 });
  assert.deepEqual(geometry(result.png), [100, 50]);
  assert.equal(result.svg, svg);
  assert.deepEqual(geometry(renderDocument({ format: 'svg', source: svg, maxWidth: 800 }).png), [400, 200]);
  const declared = '<?xml version="1.0" encoding="UTF-8"?>' + svg;
  assert.deepEqual(geometry(renderDocument({ format: 'svg', source: declared, maxWidth: 100 }).png), [100, 50]);
});

test('SVG source is required to be well-formed markup, not an HTML document or repaired XML', () => {
  for (const source of ['', '<html><svg/></html>', '<svg/>',
    '<svg xmlns="http://www.w3.org/2000/svg"><g></svg>',
    '<?xml bogus?>' + svg, '<?xml version="2.0"?>' + svg,
    '<?xml version="1.0"?><?xml version="1.0"?>' + svg,
    '<!DOCTYPE svg><svg xmlns="http://www.w3.org/2000/svg"/>',
    '<?xml-stylesheet href="file:///not-opened.css"?><svg xmlns="http://www.w3.org/2000/svg"/>']) {
    assert.throws(() => renderDocument({ format: 'svg', source, maxWidth: 100 }));
  }
});

test('SVG active and external resource declarations refuse before producing PNG bytes', () => {
  for (const content of ['<image href="file:///not-opened.png"/>',
    '<feImage href="https://example.invalid/not-fetched.png"/>',
    '<use href="/not-opened.svg#shape"/>',
    '<use xmlns:xlink="http://www.w3.org/1999/xlink" xlink:href="file:///not-opened.svg#shape"/>',
    '<script>alert(1)</script>', '<g onload="alert(1)"/>',
    '<foreignObject><div xmlns="http://www.w3.org/1999/xhtml">hidden</div></foreignObject>',
    '<rect xmlns="https://example.invalid/foreign"/>']) {
    const child = spawnSync(process.execPath, ['tools/pele/render.mjs'], {
      input: JSON.stringify({ format: 'svg', source: `<svg xmlns="http://www.w3.org/2000/svg">${content}</svg>`, maxWidth: 100 }),
      cwd: new URL('../../..', import.meta.url),
    });
    assert.equal(child.status, 1);
    assert.equal(child.stdout.length, 0);
    assert.ok(child.stderr.length > 0);
  }
});

test('source format is an explicit closed request decision', () => {
  for (const format of [undefined, null, 'html', 'SVG', 1]) {
    assert.throws(() => renderDocument({ format, source: svg, maxWidth: 100 }));
  }
});
