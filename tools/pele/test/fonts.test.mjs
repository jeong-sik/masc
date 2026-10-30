import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DOMParser, XMLSerializer } from '@xmldom/xmldom';
import { Resvg } from '@resvg/resvg-js';
import { readFileSync } from 'node:fs';
import { renderDocument } from '../engine.mjs';

function pixelBounds(renderer) {
  const image = renderer.render();
  const pixels = image.pixels;
  let left = image.width, top = image.height, right = -1, bottom = -1;
  for (let y = 0; y < image.height; y++) for (let x = 0; x < image.width; x++) {
    if (pixels[(y * image.width + x) * 4 + 3] === 0) continue;
    left = Math.min(left, x); right = Math.max(right, x);
    top = Math.min(top, y); bottom = Math.max(bottom, y);
  }
  assert.ok(right >= left && bottom >= top);
  return { width: right - left + 1, height: bottom - top + 1,
    top, bottom, centerY: (top + bottom) / 2 };
}

function glyphGeometry(svg, label) {
  const document = new DOMParser().parseFromString(svg, 'image/svg+xml');
  const root = document.documentElement;
  const text = Array.from(root.getElementsByTagName('text'))
    .find(element => element.textContent === label);
  assert.ok(text, `missing rendered label ${label}`);
  // Keep the generated font inheritance and transforms, while excluding shapes
  // and other labels from resvg's measured glyph bounding box.
  const lineage = new Set();
  for (let element = text; element; element = element.parentNode) lineage.add(element);
  function isolate(element) {
    if (element === text) return;
    for (const child of Array.from(element.childNodes)) {
      if (lineage.has(child)) isolate(child);
      else element.removeChild(child);
    }
  }
  isolate(root);
  return pixelBounds(new Resvg(new XMLSerializer().serializeToString(document)));
}

function referenceGeometry(label, fontSize) {
  return pixelBounds(new Resvg('<svg xmlns="http://www.w3.org/2000/svg" width="400" height="100"'
    + ` style="font-family:sans-serif;font-size:${fontSize}px">`
    + `<text x="0" y="60">${label}</text></svg>`));
}

test('inherited Pele glyphs use the measured font size while edge and authored overrides retain their hierarchy', () => {
  const source = 'flowchart LR\n A[HHHH] -->|EEEE| B[BBBB]:::small\n classDef small font-size:20px';
  for (const fontSize of [16, 34]) {
    const result = renderDocument({ format: 'mermaid', source, maxWidth: 1600, fontSize });
    const labels = fontSize === 16 ? [['HHHH', 16]]
      : [['HHHH', 34], ['EEEE', 29.75], ['BBBB', 42.5]];
    for (const [label, expectedSize] of labels) {
      const actual = glyphGeometry(result.svg, label);
      const expected = referenceGeometry(label, expectedSize);
      for (const axis of ['width', 'height']) {
        // Isolated source/reference glyphs can land on different subpixels.
        assert.ok(Math.abs(actual[axis] - expected[axis]) <= 1,
          `${label} font ${fontSize}: actual ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
      }
    }
  }
});

test('physical density scales pie legend spacing with its glyphs without overlap', () => {
  const result = renderDocument({ format: 'mermaid', maxWidth: 1600, fontSize: 34,
    source: 'pie\n "HHHH":6\n "HHHHH":3\n "HHHHHH":2' });
  const labels = ['HHHH', 'HHHHH', 'HHHHHH'].map(label => glyphGeometry(result.svg, label));
  for (let index = 1; index < labels.length; index++) {
    const previous = labels[index - 1], current = labels[index];
    assert.ok(previous.bottom < current.top, 'legend glyphs must not overlap');
    assert.ok(Math.abs(current.centerY - previous.centerY - 55.25) <= 1,
      'logical 26-pixel row pitch must scale with 34/16 physical density');
  }
});

test('all seven example fences retain their complete logical geometry at equivalent physical widths', () => {
  const markdown = readFileSync(new URL('../examples/color-and-themes.md', import.meta.url), 'utf8');
  const sources = [...markdown.matchAll(/```mermaid\n([\s\S]*?)```/g)].map(match => match[1]);
  assert.equal(sources.length, 7);
  const density = 34 / 16;
  const rootOf = result => new DOMParser().parseFromString(result.svg, 'image/svg+xml').documentElement;
  const children = root => Array.from(root.childNodes)
    .map(node => new XMLSerializer().serializeToString(node)).join('');
  const now = Date.UTC(2026, 9, 25, 12);
  for (const source of sources) {
    const normal = renderDocument({ format: 'mermaid', source, maxWidth: 640, fontSize: 16, now });
    const dense = renderDocument({ format: 'mermaid', source, maxWidth: 1360, fontSize: 34, now });
    assert.equal(rootOf(dense).getAttribute('viewBox'), rootOf(normal).getAttribute('viewBox'));
    assert.equal(children(rootOf(dense)), children(rootOf(normal)));
    assert.equal(dense.width, normal.width * density);
    assert.equal(dense.height, normal.height * density);
    // PNG dimensions round independently; compare the scaled raster within one pixel.
    for (const offset of [16, 20]) {
      assert.ok(Math.abs(dense.png.readUInt32BE(offset) - normal.png.readUInt32BE(offset) * density) <= 1);
    }
  }
});
