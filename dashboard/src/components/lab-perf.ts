// LabPerf — keeper-v2 performance playground for the Lab tab.
//
// Renders a live FPS meter (via the existing fps-adaptive utility) and a
// VirtualList demo that reuses the common VirtualList component. Data is
// synthetic; the surface is meant to exercise production rendering primitives.

import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { VirtualList } from './common/virtual-list'
import { onFpsChange } from '../utils/fps-adaptive'

interface PerfLogRow {
  id: string
  t: string
  level: 'info' | 'warn' | 'error'
  keeper: string
  msg: string
}

const LEVELS: PerfLogRow['level'][] = ['info', 'info', 'info', 'warn', 'error']
const KEEPERS = ['iron-claw', 'luna', 'vex', 'atlas', 'nimbus', 'ember', 'drift', 'sable', 'onyx', 'quill', 'pike', 'wren']
const MSGS = [
  'masc_amplitude_query 완료',
  'edit_file 적용',
  '컨텍스트 임계치 접근',
  'masc_compact 완료 (−61%)',
  'masc_trace_window 실패',
  'HandingOff 인계 시작',
  'preflight green',
  'round-lock 재진입 차단',
  'PR 코멘트 동기화',
  'masc_git_blame 0.4s',
]

function generateRows(count: number): PerfLogRow[] {
  return Array.from({ length: count }, (_, i) => {
    const level = LEVELS[(i * 7) % LEVELS.length] ?? 'info'
    const keeper = KEEPERS[i % KEEPERS.length] ?? 'unknown'
    const msg = MSGS[(i * 3) % MSGS.length] ?? ''
    const hh = String(16 - Math.floor(i / 900) % 16).padStart(2, '0')
    const mm = String((i * 13) % 60).padStart(2, '0')
    const ss = String((i * 29) % 60).padStart(2, '0')
    return {
      id: `perf-log-${i}`,
      t: `${hh}:${mm}:${ss}`,
      level,
      keeper,
      msg,
    }
  })
}

function FpsBadge() {
  const [fps, setFps] = useState(60)

  useEffect(() => {
    return onFpsChange(setFps)
  }, [])

  const tone = fps >= 55 ? 'ok' : fps >= 30 ? 'warn' : 'bad'
  const toneClass = {
    ok: 'text-[var(--color-status-ok)] border-[var(--ok-20)] bg-[var(--ok-10)]',
    warn: 'text-[var(--color-status-warn)] border-[var(--warn-20)] bg-[var(--warn-10)]',
    bad: 'text-[var(--color-status-err)] border-[var(--err-border)] bg-[var(--bad-soft)]',
  }[tone]

  return html`
    <span
      class=${`inline-flex items-center gap-2 rounded-[var(--r-0)] border px-2.5 py-1 text-2xs font-semibold ${toneClass}`}
      data-testid="lab-perf-fps"
    >
      <span class="size-2 rounded-full ${tone === 'ok' ? 'bg-[var(--color-status-ok)]' : tone === 'warn' ? 'bg-[var(--color-status-warn)]' : 'bg-[var(--color-status-err)]'}" aria-hidden="true"></span>
      <span>${fps} fps</span>
    </span>
  `
}

function LogRow({ row }: { row: PerfLogRow }) {
  const levelClass = {
    info: 'text-[var(--color-fg-muted)]',
    warn: 'text-[var(--color-status-warn)]',
    error: 'text-[var(--color-status-err)]',
  }[row.level]

  return html`
    <div class="flex items-center gap-3 px-3 py-2 text-xs font-mono border-b border-[var(--color-border-muted)] last:border-b-0">
      <span class="w-14 shrink-0 text-[var(--color-fg-disabled)]">${row.t}</span>
      <span class=${`w-11 shrink-0 uppercase text-2xs tracking-wider ${levelClass}`}>${row.level}</span>
      <span class="w-24 shrink-0 truncate text-[var(--color-fg-secondary)]">${row.keeper}</span>
      <span class="min-w-0 flex-1 truncate text-[var(--color-fg-primary)]">${row.msg}</span>
    </div>
  `
}

export function LabPerf() {
  const rows = useMemo(() => generateRows(2000), [])

  return html`
    <div class="v2-lab-surface flex flex-col gap-6" data-testid="lab-perf-surface">
      <div class="flex items-center justify-between gap-4 v2-monitoring-toolbar">
        <div>
          <h2 class="text-base font-semibold text-[var(--color-fg-primary)]">Performance</h2>
          <p class="text-2xs text-[var(--color-fg-muted)]">FPS meter + VirtualList windowing demo</p>
        </div>
        <${FpsBadge} />
      </div>

      <div class="v2-monitoring-panel rounded-[var(--r-2)] border border-[var(--color-border-default)] p-4">
        <div class="mb-3 flex items-center justify-between gap-3">
          <div class="text-2xs font-semibold uppercase tracking-4 text-[var(--color-fg-muted)]">
            VirtualList · ${rows.length.toLocaleString()} rows
          </div>
          <span class="text-2xs text-[var(--color-fg-disabled)]">fixed 36 px rows</span>
        </div>
        <div class="h-80 overflow-hidden rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)]">
          <${VirtualList}
            items=${rows}
            itemHeight=${36}
            getKey=${(row: PerfLogRow) => row.id}
            renderItem=${(row: PerfLogRow) => html`<${LogRow} row=${row} />`}
            className="h-full"
          />
        </div>
        <p class="mt-3 text-2xs leading-relaxed text-[var(--color-fg-muted)]">
          동일한 <code class="rounded bg-[var(--color-bg-muted)] px-1 py-0.5">LogRow</code> 컴포넌트를
          VirtualList로 윈도잉하면 보이는 슬라이스(+overscan)만 렌더링됩니다.
        </p>
      </div>
    </div>
  `
}
