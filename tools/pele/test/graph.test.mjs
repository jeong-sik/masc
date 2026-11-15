import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderDocument } from '../engine.mjs';

const sampleGraph = {
  title: '기억 형성 · e-masc-the-leader',
  subtitle: '관측 범위: 최근 50 / 최대 50회 · 연결된 변화 4건 · 관련 기억 5건',
  notes: ['retained successor is not proven by this historical transition'],
  legend: {
    retained: '유지됨',
    consumed: '이전 기억',
    unconfirmed: '미확인',
    solid: '확정 전이',
    dashed: '관계 미확인',
    footer: '+/- 확대 · arrows/hjkl 이동 · 0 맞춤 · Esc 목록으로',
  },
  nodes: [
    {
      id: 'F0',
      kind: 'fact',
      tag: 'F1',
      badge: '이전 기억',
      memoryId: 'm_3698_a',
      status: 'consumed',
      lines: [
        'MASC 저장소 Git 이력은 작업 흔적일 뿐 운영자 개인의 결합 주체나 의도를 판정하지 않는다.',
      ],
    },
    {
      id: 'F1',
      kind: 'fact',
      tag: 'F2',
      badge: '이전 기억',
      memoryId: 'm_3704_b',
      status: 'consumed',
      lines: [
        'anyang-keepers 저장소 커밋 작성자 표기는 실행 환경 설정일 뿐 운영자 행동이라 단정하지 않는다.',
      ],
    },
    {
      id: 'F2',
      kind: 'fact',
      tag: 'F3',
      badge: '이전 기억',
      memoryId: 'm_3719_c',
      status: 'consumed',
      lines: [
        '계정 공유: anyang-keepers와 동일 기기 커밋은 운영 환경 공유로 해석하며 운영자 행동이라 단정하지 않는다.',
      ],
    },
    {
      id: 'F3',
      kind: 'fact',
      tag: 'F4',
      badge: '현재 유지',
      memoryId: 'm_3719_d',
      status: 'retained',
      lines: [
        '계정 공유(2026-11-10 관측): 커밋 작성자와 실행 주체를 구분하며 운영자 행동이라 단정하지 않는다.',
      ],
    },
    {
      id: 'F4',
      kind: 'fact',
      tag: 'F5',
      badge: '이전 기억',
      memoryId: 'm_3723_e',
      status: 'consumed',
      lines: [
        'anyang-keepers 레인은 keeper 또는 리더 레인이 돌려야 한다.',
      ],
    },
    {
      id: 'E0',
      kind: 'event',
      tag: '◇ 흡수',
      selected: false,
      selectedLabel: '★ 선택',
      tone: 'info',
      revision: 'r3698',
      timestamp: '2026-11-10 15:07 UTC',
      counts: '1 → 1',
      reasonLines: [],
    },
    {
      id: 'E1',
      kind: 'event',
      tag: '◇ 흡수',
      selected: false,
      selectedLabel: '★ 선택',
      tone: 'info',
      revision: 'r3704',
      timestamp: '2026-11-10 17:48 UTC',
      counts: '1 → 1',
      reasonLines: [],
    },
    {
      id: 'E2',
      kind: 'event',
      tag: '◇ 흡수',
      selected: false,
      selectedLabel: '★ 선택',
      tone: 'info',
      revision: 'r3719',
      timestamp: '2026-11-11 05:35 UTC',
      counts: '1 → 1',
      reasonLines: [],
    },
    {
      id: 'E3',
      kind: 'event',
      tag: '★ ? 관계 미확인',
      selected: true,
      selectedLabel: '★ 선택',
      tone: 'warn',
      revision: 'r3723',
      timestamp: '2026-11-13 01:01 UTC',
      counts: '1 → 1',
      reasonLines: ['retained successor is not proven by this historical transition'],
    },
  ],
  edges: [
    { from: 'F0', to: 'E0', role: 'input', dashed: false },
    { from: 'E0', to: 'F1', role: 'output', dashed: false },
    { from: 'F1', to: 'E1', role: 'input', dashed: false },
    { from: 'E1', to: 'F2', role: 'output', dashed: false },
    { from: 'F2', to: 'E2', role: 'input', dashed: false },
    { from: 'E2', to: 'F3', role: 'output', dashed: false },
    { from: 'F4', to: 'E3', role: 'input', dashed: false },
    { from: 'E3', to: 'F3', role: 'unconfirmed', dashed: true },
  ],
};

test('graph format renders untruncated rich SVG cards with dagre layout and supports raster crop', () => {
  const result = renderDocument({
    format: 'graph',
    source: JSON.stringify(sampleGraph),
    maxWidth: 1200,
    colors: { foreground: '#e5e7eb', background: '#0a0c10' },
  });
  assert.deepEqual([...result.png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  assert.ok(result.svg.includes('결합 주체나 의도를 판정하지 않는다.'));
  assert.ok(result.svg.includes('운영 환경 공유로 해석하며'));
  assert.ok(!result.svg.includes('var(--'));
  assert.ok(result.svg.includes('stroke-dasharray="6 4"'));

  const zoomed = renderDocument({
    format: 'graph',
    source: JSON.stringify(sampleGraph),
    maxWidth: 1200,
    colors: { foreground: '#e5e7eb', background: '#0a0c10' },
    raster: { width: 800, height: 600, crop: { left: 0.1, top: 0.1, right: 0.9, bottom: 0.9 } },
  });
  assert.deepEqual([...zoomed.png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  assert.ok(zoomed.png.readUInt32BE(16) <= 800);
  assert.ok(zoomed.png.readUInt32BE(20) <= 600);
});

test('graph format rejects malformed payloads and untrusted markup is escaped', () => {
  assert.throws(() => renderDocument({ format: 'graph', source: 'not json', maxWidth: 640 }));
  assert.throws(() => renderDocument({ format: 'graph', source: '{"nodes":[],"edges":[]}', maxWidth: 0 }));
  const escaped = renderDocument({
    format: 'graph',
    maxWidth: 800,
    source: JSON.stringify({
      title: '<script>alert(1)</script>',
      nodes: [{ id: 'F0', kind: 'fact', status: 'retained', lines: ['<foreignObject>bad</foreignObject>'] }],
      edges: [],
    }),
  });
  assert.ok(!escaped.svg.includes('<script>'));
  assert.ok(!escaped.svg.includes('<foreignObject>'));
  assert.ok(escaped.svg.includes('&lt;script&gt;'));
});
