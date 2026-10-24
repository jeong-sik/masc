import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DOMParser, XMLSerializer } from '@xmldom/xmldom';
import { Resvg } from '@resvg/resvg-js';
import { renderDocument } from '../engine.mjs';

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
  const bbox = new Resvg(new XMLSerializer().serializeToString(document)).getBBox();
  assert.ok(bbox);
  return [bbox.width, bbox.height];
}

function referenceGeometry(label, fontSize) {
  const bbox = new Resvg('<svg xmlns="http://www.w3.org/2000/svg" width="400" height="100"'
    + ` style="font-family:sans-serif;font-size:${fontSize}px">`
    + `<text x="0" y="60">${label}</text></svg>`).getBBox();
  assert.ok(bbox);
  return [bbox.width, bbox.height];
}

test('inherited Pele glyphs use the measured font size while edge and authored overrides retain their hierarchy', () => {
  const source = 'flowchart LR\n A[HHHH] -->|EEEE| B[BBBB]:::small\n classDef small font-size:20px';
  for (const fontSize of [16, 34]) {
    const result = renderDocument({ format: 'mermaid', source, maxWidth: 1600, fontSize });
    const labels = fontSize === 16 ? [['HHHH', 16]]
      : [['HHHH', 34], ['EEEE', 30], ['BBBB', 20]];
    for (const [label, expectedSize] of labels) {
      const actual = glyphGeometry(result.svg, label);
      const expected = referenceGeometry(label, expectedSize);
      for (let axis = 0; axis < 2; axis++) {
        assert.ok(Math.abs(actual[axis] - expected[axis]) < 0.0001,
          `${label} font ${fontSize}: actual ${actual}, expected ${expected}`);
      }
    }
  }
});
