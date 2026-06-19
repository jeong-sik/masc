// LabPerf — keeper-v2 performance playground for the Lab tab.
//
// Renders a live FPS meter (via the existing fps-adaptive utility) and a
// VirtualList demo that reuses the common VirtualList component. Data is
// synthetic; the surface is meant to exercise production rendering primitives.

import { html } from 'htm/preact'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks'
import { VirtualList } from './common/virtual-list'
import { onFpsChange } from '../utils/fps-adaptive'

interface PerfLogRow {
  id: string
  t: string
  level: 'info' | 'warn' | 'error'
  keeper: string
  msg: string
}

type PerfDemoMode = 'virtual-list' | 'content-visibility'

interface PlatformCapability {
  id: string
  label: string
  detail: string
  supported: boolean
}

type ViewTransitionDocument = Document & {
  startViewTransition?: (updateCallback: () => void) => unknown
}

interface ElementSize {
  width: number
  height: number
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

function supportsCss(property: string, value: string): boolean {
  if (typeof CSS === 'undefined' || typeof CSS.supports !== 'function') return false
  return CSS.supports(property, value)
}

function readPlatformCapabilities(): PlatformCapability[] {
  const doc = typeof document === 'undefined' ? null : document
  return [
    {
      id: 'resize-observer',
      label: 'ResizeObserver',
      detail: 'viewport measurement for exact windowing math',
      supported: typeof ResizeObserver !== 'undefined',
    },
    {
      id: 'intersection-observer',
      label: 'IntersectionObserver',
      detail: 'lazy mount and infinite-scroll sentinels',
      supported: typeof IntersectionObserver !== 'undefined',
    },
    {
      id: 'view-transition',
      label: 'View Transitions',
      detail: 'animated mode swaps when the browser supports it',
      supported: !!doc && typeof (doc as ViewTransitionDocument).startViewTransition === 'function',
    },
    {
      id: 'content-visibility',
      label: 'content-visibility',
      detail: 'layout and paint skipped for off-screen DOM rows',
      supported: supportsCss('content-visibility', 'auto'),
    },
  ]
}

function readElementSize(element: HTMLElement): ElementSize {
  const rect = element.getBoundingClientRect()
  return {
    width: Math.round(rect.width || element.clientWidth),
    height: Math.round(rect.height || element.clientHeight),
  }
}

function useMeasuredElement() {
  const ref = useRef<HTMLDivElement>(null)
  const [size, setSize] = useState<ElementSize>({ width: 0, height: 0 })

  useLayoutEffect(() => {
    const element = ref.current
    if (!element) return undefined

    setSize(readElementSize(element))
    if (typeof ResizeObserver === 'undefined') return undefined

    const observer = new ResizeObserver(entries => {
      const entry = entries[0]
      if (!entry) return
      const box = entry.borderBoxSize?.[0]
      if (box) {
        setSize({
          width: Math.round(box.inlineSize),
          height: Math.round(box.blockSize),
        })
        return
      }
      setSize({
        width: Math.round(entry.contentRect.width),
        height: Math.round(entry.contentRect.height),
      })
    })
    observer.observe(element)
    return () => observer.disconnect()
  }, [])

  return { ref, size }
}

function useInViewProbe() {
  const ref = useRef<HTMLDivElement>(null)
  const [inView, setInView] = useState(false)

  useEffect(() => {
    const element = ref.current
    if (!element) return undefined
    if (typeof IntersectionObserver === 'undefined') {
      setInView(true)
      return undefined
    }

    const observer = new IntersectionObserver(entries => {
      setInView(entries.some(entry => entry.isIntersecting))
    }, { rootMargin: '80px', threshold: 0.1 })
    observer.observe(element)
    return () => observer.disconnect()
  }, [])

  return { ref, inView }
}

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

function PlatformBadges({ capabilities }: { capabilities: PlatformCapability[] }) {
  return html`
    <div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-4" data-testid="lab-perf-platform">
      ${capabilities.map(capability => {
        const tone = capability.supported
          ? 'border-success/20 bg-success/10 text-success'
          : 'border-border bg-surface-subtle text-text-tertiary'
        return html`
          <div
            key=${capability.id}
            class="rounded-xl border border-border bg-surface-subtle/70 px-3 py-3"
            data-testid=${`lab-perf-capability-${capability.id}`}
            data-supported=${capability.supported ? 'true' : 'false'}
          >
            <div class="mb-1 flex items-center justify-between gap-2">
              <span class="text-[12px] font-semibold text-text-primary">${capability.label}</span>
              <span class=${`rounded-md border px-1.5 py-0.5 text-[10px] font-semibold uppercase ${tone}`}>
                ${capability.supported ? 'native' : 'fallback'}
              </span>
            </div>
            <p class="text-[12px] leading-relaxed text-text-tertiary">${capability.detail}</p>
          </div>
        `
      })}
    </div>
  `
}

function ObserverProbePanel() {
  const measured = useMeasuredElement()
  const sentinel = useInViewProbe()

  return html`
    <div class="grid grid-cols-1 gap-4 lg:grid-cols-2" data-testid="lab-perf-observer-probes">
      <section class="rounded-2xl border border-border bg-surface-subtle/70 p-4">
        <div class="mb-3 flex items-center justify-between gap-3">
          <div>
            <h3 class="text-[13px] font-semibold text-text-primary">ResizeObserver · useSize</h3>
            <p class="text-[12px] text-text-tertiary">Measured after layout; updates when the panel changes size.</p>
          </div>
          <span class="rounded-md border border-border bg-surface-page px-2 py-1 font-mono text-[11px] text-text-secondary" data-testid="lab-perf-size-readout">
            ${measured.size.width}×${measured.size.height}
          </span>
        </div>
        <div
          ref=${measured.ref}
          class="rounded-xl border border-border bg-surface-page p-4"
          data-testid="lab-perf-size-target"
        >
          <div class="h-12 rounded-lg border border-success/20 bg-success/10 px-3 py-2 text-[12px] leading-relaxed text-text-secondary">
            The measured target is ordinary dashboard chrome, not a synthetic canvas.
          </div>
        </div>
      </section>

      <section class="rounded-2xl border border-border bg-surface-subtle/70 p-4">
        <div class="mb-3 flex items-center justify-between gap-3">
          <div>
            <h3 class="text-[13px] font-semibold text-text-primary">IntersectionObserver · useInView</h3>
            <p class="text-[12px] text-text-tertiary">The sentinel reports whether this demo is near the viewport.</p>
          </div>
          <span
            class=${`rounded-md border px-2 py-1 text-[11px] font-semibold ${sentinel.inView ? 'border-success/20 bg-success/10 text-success' : 'border-border bg-surface-page text-text-tertiary'}`}
            data-testid="lab-perf-inview-readout"
            data-in-view=${sentinel.inView ? 'true' : 'false'}
          >
            ${sentinel.inView ? 'in view' : 'waiting'}
          </span>
        </div>
        <div
          ref=${sentinel.ref}
          class="rounded-xl border border-border bg-surface-page p-4 text-[12px] leading-relaxed text-text-secondary"
          data-testid="lab-perf-inview-target"
        >
          Sentinel observed with rootMargin 80px and threshold 0.1.
        </div>
      </section>
    </div>
  `
}

function NativeDialogDemo() {
  const [open, setOpen] = useState(false)
  const dialogRef = useRef<HTMLDialogElement>(null)

  useEffect(() => {
    const dialog = dialogRef.current
    if (!dialog) return

    if (open) {
      if (typeof dialog.showModal === 'function' && !dialog.open) {
        try {
          dialog.showModal()
        } catch {
          dialog.setAttribute('open', '')
        }
      } else {
        dialog.setAttribute('open', '')
      }
      return
    }

    if (dialog.open) {
      if (typeof dialog.close === 'function') dialog.close()
      else dialog.removeAttribute('open')
    }
  }, [open])

  useEffect(() => {
    const dialog = dialogRef.current
    if (!dialog) return undefined
    const onClose = () => setOpen(false)
    const onCancel = () => setOpen(false)
    dialog.addEventListener('close', onClose)
    dialog.addEventListener('cancel', onCancel)
    return () => {
      dialog.removeEventListener('close', onClose)
      dialog.removeEventListener('cancel', onCancel)
    }
  }, [])

  return html`
    <section class="rounded-2xl border border-border bg-surface-subtle/70 p-4" data-testid="lab-perf-dialog-demo">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h3 class="text-[13px] font-semibold text-text-primary">Native dialog</h3>
          <p class="text-[12px] text-text-tertiary">Real top-layer modal path from the platform performance layer.</p>
        </div>
        <button
          type="button"
          class="rounded-lg border border-border bg-surface-page px-3 py-1.5 text-[12px] font-semibold text-text-primary hover:border-accent"
          data-testid="lab-perf-dialog-open"
          aria-haspopup="dialog"
          onClick=${() => setOpen(true)}
        >
          Open dialog
        </button>
      </div>

      <dialog
        ref=${dialogRef}
        class="fixed inset-0 m-auto max-h-[calc(100vh-48px)] w-[min(420px,calc(100vw-32px))] overflow-hidden rounded-2xl border border-border bg-surface-panel p-0 text-text-primary shadow-[0_24px_80px_rgba(0,0,0,0.55)] backdrop:bg-black/70"
        aria-labelledby="lab-perf-dialog-title"
        data-testid="lab-perf-native-dialog"
        onClick=${(event: MouseEvent) => {
          if (event.target === event.currentTarget) setOpen(false)
        }}
      >
        <div class="border-b border-border px-5 py-4">
          <h3 id="lab-perf-dialog-title" class="text-[15px] font-semibold">Native top-layer dialog</h3>
          <p class="mt-1 text-[12px] leading-relaxed text-text-tertiary">
            showModal, Esc/cancel, close events, and backdrop are owned by the browser.
          </p>
        </div>
        <div class="px-5 py-4 text-[13px] leading-relaxed text-text-secondary">
          This closes the remaining visible gap from the keeper-v2 performance export without adding a custom modal stack.
        </div>
        <div class="flex justify-end border-t border-border px-5 py-4">
          <button
            type="button"
            class="rounded-lg border border-border bg-surface-page px-3 py-1.5 text-[12px] font-semibold text-text-primary"
            data-testid="lab-perf-dialog-close"
            onClick=${() => setOpen(false)}
          >
            Close
          </button>
        </div>
      </dialog>
    </section>
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

function ContentVisibilityList({ rows }: { rows: PerfLogRow[] }) {
  return html`
    <div
      class="h-80 overflow-y-auto rounded-xl border border-border bg-surface-page"
      data-testid="lab-perf-cv-list"
      data-cv-total=${rows.length}
    >
      ${rows.map(row => html`
        <div
          key=${row.id}
          class="virtual-list-fallback-row"
          data-testid="lab-perf-cv-row"
          style=${{
            contentVisibility: 'auto',
            containIntrinsicSize: 'auto 48px',
          }}
        >
          <${LogRow} row=${row} />
        </div>
      `)}
    </div>
  `
}

export function LabPerf() {
  const rows = useMemo(() => generateRows(2000), [])
  const cvRows = useMemo(() => rows.slice(0, 180), [rows])
  const capabilities = useMemo(readPlatformCapabilities, [])
  const [mode, setMode] = useState<PerfDemoMode>('virtual-list')

  const setModeWithTransition = useCallback((nextMode: PerfDemoMode) => {
    if (nextMode === mode) return
    const mutate = () => setMode(nextMode)
    const doc = typeof document === 'undefined' ? null : document
    const startViewTransition = doc ? (doc as ViewTransitionDocument).startViewTransition : undefined
    if (typeof startViewTransition === 'function') {
      try {
        startViewTransition.call(doc, mutate)
        return
      } catch {
        // Use the plain state update if the browser rejects the transition.
      }
    }
    mutate()
  }, [mode])

  return html`
    <div class="v2-lab-surface ss-surface bg-surface-page flex flex-col gap-6 px-6 py-6" data-testid="lab-perf-surface">
      <div class="flex flex-wrap items-center justify-between gap-4 v2-monitoring-toolbar">
        <div>
          <h2 class="text-[18px] font-bold text-text-primary">Performance</h2>
          <p class="text-[13px] text-text-tertiary">FPS meter, VirtualList, content-visibility, native dialog, and observer probes</p>
        </div>
        <div class="flex flex-wrap items-center justify-end gap-2">
          <${FpsBadge} />
          <div class="inline-flex rounded-lg border border-border bg-surface-subtle p-1" aria-label="Performance demo mode">
            <button
              type="button"
              class=${`rounded-md px-2.5 py-1 text-[12px] font-semibold transition ${mode === 'virtual-list' ? 'bg-surface-page text-text-primary shadow-sm' : 'text-text-tertiary hover:text-text-secondary'}`}
              aria-pressed=${mode === 'virtual-list'}
              data-testid="lab-perf-mode-virtual-list"
              onClick=${() => setModeWithTransition('virtual-list')}
            >
              VirtualList
            </button>
            <button
              type="button"
              class=${`rounded-md px-2.5 py-1 text-[12px] font-semibold transition ${mode === 'content-visibility' ? 'bg-surface-page text-text-primary shadow-sm' : 'text-text-tertiary hover:text-text-secondary'}`}
              aria-pressed=${mode === 'content-visibility'}
              data-testid="lab-perf-mode-content-visibility"
              onClick=${() => setModeWithTransition('content-visibility')}
            >
              Content visibility
            </button>
          </div>
        </div>
      </div>

      <${PlatformBadges} capabilities=${capabilities} />

      <${ObserverProbePanel} />

      <${NativeDialogDemo} />

      <div class="ss-card v2-monitoring-panel rounded-2xl border border-border p-6">
        <div class="mb-3 flex flex-wrap items-center justify-between gap-3">
          <div class="text-[12px] font-semibold uppercase tracking-[0.05em] text-text-secondary">
            ${mode === 'virtual-list'
              ? `VirtualList · ${rows.length.toLocaleString()} rows`
              : `Content visibility · ${cvRows.length.toLocaleString()} variable rows`}
          </div>
          <span class="text-[11px] text-text-disabled">
            ${mode === 'virtual-list' ? 'fixed 36 px rows' : 'DOM retained; off-screen paint skipped'}
          </span>
        </div>
        ${mode === 'virtual-list' ? html`
          <div class="h-80 overflow-hidden rounded-xl border border-border bg-surface-page" data-testid="lab-perf-virtual-list">
            <${VirtualList}
              items=${rows}
              itemHeight=${36}
              getKey=${(row: PerfLogRow) => row.id}
              renderItem=${(row: PerfLogRow) => html`<${LogRow} row=${row} />`}
              className="h-full"
            />
          </div>
        ` : html`
          <${ContentVisibilityList} rows=${cvRows} />
        `}
        <p class="mt-3 text-[13px] leading-relaxed text-text-tertiary">
          동일한 <code class="rounded bg-surface-subtle px-1 py-0.5 text-text-primary">LogRow</code> 컴포넌트로
          true windowing과 content-visibility 경로를 비교합니다.
        </p>
      </div>
    </div>
  `
}
