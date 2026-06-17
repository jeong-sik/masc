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
    ok: 'text-success border-success/20 bg-success/10',
    warn: 'text-warning border-warning/20 bg-warning/10',
    bad: 'text-destructive border-destructive/20 bg-destructive/10',
  }[tone]

  const dotClass = {
    ok: 'bg-success',
    warn: 'bg-warning',
    bad: 'bg-destructive',
  }[tone]

  return html`
    <span
      class=${`inline-flex items-center gap-2 rounded-md border px-2.5 py-1 text-[11px] font-semibold ${toneClass}`}
      data-testid="lab-perf-fps"
    >
      <span class="size-2 rounded-full ${dotClass}" aria-hidden="true"></span>
      <span>${fps} fps</span>
    </span>
  `
}

function LogRow({ row }: { row: PerfLogRow }) {
  const levelClass = {
    info: 'text-text-tertiary',
    warn: 'text-warning',
    error: 'text-destructive',
  }[row.level]

  return html`
    <div class="flex items-center gap-3 px-3 py-2 text-[14px] font-mono border-b border-border last:border-b-0">
      <span class="w-14 shrink-0 text-text-disabled">${row.t}</span>
      <span class=${`w-11 shrink-0 uppercase text-[11px] tracking-wider ${levelClass}`}>${row.level}</span>
      <span class="w-24 shrink-0 truncate text-text-secondary">${row.keeper}</span>
      <span class="min-w-0 flex-1 truncate text-text-primary">${row.msg}</span>
    </div>
  `
}

export function LabPerf() {
  const rows = useMemo(() => generateRows(2000), [])

  return html`
    <div class="v2-lab-surface ss-surface bg-surface-page flex flex-col gap-6 px-6 py-6" data-testid="lab-perf-surface">
      <div class="flex items-center justify-between gap-4 v2-monitoring-toolbar">
        <div>
          <h2 class="text-[18px] font-bold text-text-primary">Performance</h2>
          <p class="text-[13px] text-text-tertiary">FPS meter + VirtualList windowing demo</p>
        </div>
        <${FpsBadge} />
      </div>

      <div class="ss-card v2-monitoring-panel rounded-2xl border border-border p-6">
        <div class="mb-3 flex items-center justify-between gap-3">
          <div class="text-[12px] font-semibold uppercase tracking-[0.05em] text-text-secondary">
            VirtualList · ${rows.length.toLocaleString()} rows
          </div>
          <span class="text-[11px] text-text-disabled">fixed 36 px rows</span>
        </div>
        <div class="h-80 overflow-hidden rounded-xl border border-border bg-surface-page">
          <${VirtualList}
            items=${rows}
            itemHeight=${36}
            getKey=${(row: PerfLogRow) => row.id}
            renderItem=${(row: PerfLogRow) => html`<${LogRow} row=${row} />`}
            className="h-full"
          />
        </div>
        <p class="mt-3 text-[13px] leading-relaxed text-text-tertiary">
          동일한 <code class="rounded bg-surface-subtle px-1 py-0.5 text-text-primary">LogRow</code> 컴포넌트를
          VirtualList로 윈도잉하면 보이는 슬라이스(+overscan)만 렌더링됩니다.
        </p>
      </div>
    </div>
  `
}
