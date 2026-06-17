// MemoryExplore — keeper-v2 memory linkage exploration surface.
//
// Composes MemoryLens, MemoryLineageRail, and GoalDossier into a single Lab
// section that demonstrates how a memory checkpoint fans out to goals, tasks,
// and board posts. All data is mock/sample.

import { html } from 'htm/preact'
import { MemoryLens } from './memory-lens'
import { MemoryLineageRail } from './memory-lineage-rail'
import { GoalDossier } from './goal-dossier'
import type { MemoryNode, MemoryNodeType, MemoryKeeper } from './memory-primitives'

const NODE_TYPES: Record<string, MemoryNodeType> = {
  memory: { kr: '기억', g: '◆', c: 'var(--volt)' },
  goal: { kr: '골', g: '◎', c: 'var(--accent-ice)' },
  task: { kr: '태스크', g: '▣', c: 'var(--status-ok)' },
  board: { kr: '보드', g: '◈', c: '#8a6cf0' },
  issue: { kr: '이슈', g: '⚠', c: 'var(--accent-viscera)' },
  snapshot: { kr: '스냅샷', g: '◷', c: 'var(--accent-ice)' },
}

const KEEPERS: Record<string, MemoryKeeper> = {
  nick0cave: { s: 'NK', c: '#e0a82e' },
  sangsu: { s: 'SS', c: '#5b9cf0' },
  operator: { s: 'OP', c: '#e0b057' },
}

const NODES: Record<string, MemoryNode> = {
  mem: {
    type: 'memory',
    title: 'compact()가 라운드 락 보유 중 호출돼 round-jitter 발생',
    kp: 'nick0cave',
    meta: 'insight · 체크포인트',
    ns: 'core/scheduler',
  },
  mem2: {
    type: 'memory',
    title: 'c7be26acfb — compact() 최초 도입 커밋',
    kp: 'nick0cave',
    meta: 'origin · 회귀 출발점',
    ns: 'core/scheduler',
  },
  goal: {
    type: 'goal',
    title: 'scheduler p95 round-jitter < 50ms',
    kp: 'nick0cave',
    meta: '진행 47% · D-3',
    ns: 'core/scheduler',
  },
  task1: {
    type: 'task',
    title: 'compact() 호출부를 라운드 락 밖으로 격리',
    kp: 'sangsu',
    meta: 'open · 핸드오프 수신',
    ns: 'core/runtime',
  },
  task2: {
    type: 'task',
    title: 'round-lock 재진입 회귀 테스트 추가',
    kp: 'nick0cave',
    meta: 'done · 84/84',
    ns: 'core/scheduler',
  },
  board: {
    type: 'board',
    title: 'scheduler 공지 — drifter restart 승인 대기',
    kp: 'operator',
    meta: '@operator 멘션',
    ns: 'core/scheduler',
  },
}

const EDGES = [
  { source: 'mem', target: 'goal', rel: '진단' },
  { source: 'mem', target: 'task1', rel: '파생' },
  { source: 'mem', target: 'task2', rel: '검증' },
  { source: 'mem', target: 'board', rel: '게시' },
  { source: 'mem', target: 'mem2', rel: '기원' },
  { source: 'goal', target: 'task1', rel: '해소' },
  { source: 'goal', target: 'task2', rel: '해소' },
  { source: 'board', target: 'task1', rel: '승인 대기' },
]

const LINEAGE_STEPS = [
  { id: 'mem2', t: '13:18', rel: '기원 — 이 커밋이 회귀의 출발점' },
  { id: 'mem', t: '13:49', rel: '통찰 기록 — 락 보유 중 compact() 호출 확인', anchor: true },
  { id: 'goal', t: '13:50', rel: '골 진단 갱신 — jitter 목표에 연결' },
  { id: 'task1', t: '13:52', rel: '태스크 파생 → sangsu 핸드오프' },
  { id: 'board', t: '13:55', rel: '보드 게시 — restart 승인 요청' },
  { id: 'task2', t: '14:08', rel: '회귀 테스트 통과 84/84' },
]

const GOAL = {
  title: 'scheduler p95 round-jitter < 50ms',
  kp: 'nick0cave',
  ns: 'core/scheduler',
  pct: 47,
  deadline: 'D-3 마감',
}

const SNAPS = [
  { t: '06-08', pct: 12, note: 'baseline' },
  { t: '06-09', pct: 28, note: '회귀 테스트 통과' },
  { t: '06-11', pct: 47, note: '현재', now: true },
]

const RELATED = {
  task: [
    { title: 'compact() 호출부를 라운드 락 밖으로 격리', kp: 'sangsu', meta: 'open · 핸드오프 수신', state: 'open' as const },
    { title: 'round-lock 재진입 회귀 테스트 추가', kp: 'nick0cave', meta: 'done · 84/84', state: 'done' as const },
  ],
  issue: [
    { title: 'round-jitter p95 380ms 스파이크 (7회)', kp: 'nick0cave', meta: '원인 규명됨 · L93 lock', state: 'open' as const },
    { title: 'drifter overflow → restart 대기', kp: 'operator', meta: 'blocked · 승인 대기', state: 'block' as const },
  ],
  memory: [
    { title: 'compact()가 라운드 락 보유 중 호출 (insight)', kp: 'nick0cave', meta: '13:49 체크포인트', state: 'ctx' as const },
    { title: 'c7be26acfb — compact() 최초 도입 커밋', kp: 'nick0cave', meta: 'origin', state: 'ctx' as const },
  ],
}

const LEDGER = [
  ['누적 trace', '287'],
  ['활성 시간', '6h 12m'],
  ['태스크', '2 · ✓1'],
  ['이슈', '2'],
  ['기억', '2'],
  ['참여 keeper', '3'],
] as const

export function MemoryExplore() {
  return html`
    <div class="v2-lab-surface flex flex-col gap-6" data-testid="memory-explore-surface">
      <div class="flex items-center justify-between gap-4 v2-monitoring-toolbar">
        <div>
          <h2 class="text-base font-semibold text-[var(--color-fg-primary)]">Memory Linkage Explore</h2>
          <p class="text-2xs text-[var(--color-fg-muted)]">메모리 체크포인트 → 골 → 태스크 → 보드 연결망</p>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <div class="v2-monitoring-panel rounded-[var(--r-2)] border border-[var(--color-border-default)] overflow-hidden">
          <${MemoryLens}
            nodes=${NODES}
            edges=${EDGES}
            nodeTypes=${NODE_TYPES}
            keepers=${KEEPERS}
            start="mem"
            testId="memory-explore-lens"
          />
        </div>

        <div class="v2-monitoring-panel rounded-[var(--r-2)] border border-[var(--color-border-default)] overflow-hidden">
          <${MemoryLineageRail}
            steps=${LINEAGE_STEPS}
            nodes=${NODES}
            nodeTypes=${NODE_TYPES}
            keepers=${KEEPERS}
            testId="memory-explore-lineage"
          />
        </div>
      </div>

      <div class="v2-monitoring-panel rounded-[var(--r-2)] border border-[var(--color-border-default)] overflow-hidden">
        <${GoalDossier}
          goal=${GOAL}
          nodeTypes=${NODE_TYPES}
          keepers=${KEEPERS}
          snaps=${SNAPS}
          related=${RELATED}
          ledger=${LEDGER}
          testId="memory-explore-dossier"
        />
      </div>
    </div>
  `
}
