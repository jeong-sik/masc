import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DOMParser } from '@xmldom/xmldom';
import { renderDocument } from '../engine.mjs';

test('captured epoch milliseconds freeze Gantt geometry and reject invalid clock requests', () => {
  const request = { format: 'mermaid', maxWidth: 640, now: Date.UTC(2026, 9, 25, 12),
    source: 'gantt\n dateFormat YYYY-MM-DD\n section work\n A :a,2026-10-25,1d\n B :b,after a,1d' };
  const first = renderDocument(request);
  const repeated = renderDocument(request);
  assert.equal(repeated.svg, first.svg);
  assert.deepEqual(repeated.png, first.png);
  const marker = result => {
    const document = new DOMParser().parseFromString(result.svg, 'image/svg+xml');
    const group = Array.from(document.getElementsByTagName('g'))
      .find(element => element.getAttribute('class') === 'pele-today');
    assert.ok(group, 'the fixture must exercise the moving Gantt clock marker');
    return group.firstChild.getAttribute('d');
  };
  const later = renderDocument({ ...request, now: Date.UTC(2026, 9, 26, 12) });
  assert.notEqual(marker(later), marker(first));
  assert.notDeepEqual(later.png, first.png);
  for (const now of [null, 0.5, Infinity, '2026-10-25', Number.MAX_SAFE_INTEGER + 1,
    8640000000000001, -8640000000000001]) {
    assert.throws(() => renderDocument({ ...request, now }), /now/);
  }
});
