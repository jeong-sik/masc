// KpiStrip perf benchmark — Preact KpiStrip vs Solid KpiStripIsland.
//
// Honest end-to-end measurement: time from `render(...)` start to the
// moment the DOM has all expected `role="listitem"` cells. This matches
// user-perceived latency.
//
// Why a naive `t1 - t0` around `render(...)` would lie: KpiStripIsland's
// first synchronous render produces an empty `<div>`. The actual Solid
// mount happens inside a `useEffect` callback that fires at task tier.
// Measuring only the sync portion shows Solid as ~zero — that's the
// time to render an empty div, not the time to render cells.
//
// Both sides go through Preact's `render()` because that is the
// production entry point — KpiStripIsland is itself a Preact component.

import { render } from 'preact'
import { html } from 'htm/preact'
import { KpiStrip } from '../../src/components/kpi-strip'
import { KpiCell } from '../../src/components/kpi-cell'
import {
  KpiStripIsland,
  type KpiStripIslandData,
} from '../../src/components/kpi-strip-island'
import { KpiStripIslandSync } from '../../src/components/kpi-strip-island-sync'

interface SeedRow {
  total: number
  ok: number
  warn: number
  err: number
  pending: number
  rate: number
}

function makeSeed(count: number): SeedRow[] {
  const out: SeedRow[] = []
  for (let i = 0; i < count; i += 1) {
    out.push({
      total: 100 + i,
      ok: 70 + (i % 30),
      warn: 10 + (i % 5),
      err: 2 + (i % 3),
      pending: 5 + (i % 7),
      rate: Math.round(((i % 100) / 100) * 1000) / 10,
    })
  }
  return out
}

function rowToCells(row: SeedRow, cellsPerStrip: number): KpiStripIslandData['cells'] {
  const all = [
    { variant: 'stacked' as const, label: 'total', value: row.total },
    { variant: 'stacked' as const, label: 'ok', value: row.ok, kind: 'ok' as const },
    { variant: 'stacked' as const, label: 'warn', value: row.warn, kind: 'warn' as const },
    { variant: 'stacked' as const, label: 'err', value: row.err, kind: 'err' as const },
    { variant: 'stacked' as const, label: 'pending', value: row.pending },
    { variant: 'stacked' as const, label: 'rate', value: `${row.rate}%` },
  ]
  return all.slice(0, cellsPerStrip)
}

const preactHost = document.getElementById('preact-host') as HTMLElement
const islandHost = document.getElementById('island-host') as HTMLElement
const resultsEl = document.getElementById('results') as HTMLElement
const countInput = document.getElementById('count') as HTMLInputElement
const cellsInput = document.getElementById('cells') as HTMLInputElement

interface BenchResult {
  preactMountMs: number
  islandMountMs: number
  preactUpdateMs: number[]
  islandUpdateMs: number[]
}

function format(label: string, ms: number): string {
  return `${label.padEnd(30)}${ms.toFixed(2)} ms`
}

function summariseUpdates(values: number[]): string {
  if (values.length === 0) return '(no updates)'
  const avg = values.reduce((a, b) => a + b, 0) / values.length
  const min = Math.min(...values)
  const max = Math.max(...values)
  return `min=${min.toFixed(2)} avg=${avg.toFixed(2)} max=${max.toFixed(2)} ms (${values.length} samples)`
}

function reportResult(label: string, r: BenchResult, count: number, cellsPerStrip: number): void {
  const expected = count * cellsPerStrip
  const mountWinner = r.islandMountMs < r.preactMountMs ? 'Solid' : 'Preact'
  const mountRatio = (r.islandMountMs / r.preactMountMs).toFixed(2)

  const preactUpdAvg = r.preactUpdateMs.length
    ? r.preactUpdateMs.reduce((a, b) => a + b, 0) / r.preactUpdateMs.length
    : NaN
  const islandUpdAvg = r.islandUpdateMs.length
    ? r.islandUpdateMs.reduce((a, b) => a + b, 0) / r.islandUpdateMs.length
    : NaN

  const updWinner = islandUpdAvg < preactUpdAvg ? 'Solid' : 'Preact'
  const updRatio = preactUpdAvg ? (islandUpdAvg / preactUpdAvg).toFixed(2) : 'n/a'

  const block = [
    `=== ${label} (strips=${count}, cells/strip=${cellsPerStrip}, expected listitems=${expected}) ===`,
    format('Preact KpiStrip mount→DOM:', r.preactMountMs),
    format('Solid KpiStripIsland mount→DOM:', r.islandMountMs),
    `  → mount winner: ${mountWinner} (Solid/Preact = ${mountRatio})`,
    `Preact updates→DOM:   ${summariseUpdates(r.preactUpdateMs)}`,
    `Solid updates→DOM:    ${summariseUpdates(r.islandUpdateMs)}`,
    `  → update winner: ${updWinner} (Solid/Preact = ${updRatio})`,
    '',
  ]
  resultsEl.textContent = (resultsEl.textContent ?? '') + block.join('\n') + '\n'
  console.log(block.join('\n'))
}

function clear(): void {
  render(null, preactHost)
  render(null, islandHost)
}

// End-to-end measurement: fire renderFn, then resolve when the host has
// `expected` listitem children. Uses requestAnimationFrame to poll the
// DOM — both Preact (synchronous) and Solid (useEffect → solidRender)
// settle within a few rAF ticks.
function timeRenderToDom(
  renderFn: () => void,
  host: HTMLElement,
  expected: number,
  budgetMs = 5000,
): Promise<number> {
  return new Promise((resolve, reject) => {
    const start = performance.now()
    const deadline = start + budgetMs

    renderFn()

    const check = (): void => {
      const cells = host.querySelectorAll('[role="listitem"]').length
      const now = performance.now()
      if (cells >= expected) {
        resolve(now - start)
        return
      }
      if (now > deadline) {
        reject(new Error(`timed out waiting for ${expected} listitems (have ${cells})`))
        return
      }
      requestAnimationFrame(check)
    }
    requestAnimationFrame(check)
  })
}

async function runMount(count: number, cellsPerStrip: number): Promise<{
  preactMountMs: number
  islandMountMs: number
  rows: SeedRow[]
}> {
  const rows = makeSeed(count)
  const expected = count * cellsPerStrip

  clear()
  const preactMountMs = await timeRenderToDom(
    () => {
      render(
        html`<div>${rows.map((r) => html`
          <${KpiStrip} ariaLabel="bench" cols=${cellsPerStrip}>
            ${rowToCells(r, cellsPerStrip).map((cell) => html`<${KpiCell} ...${cell} />`)}
          <//>
        `)}</div>`,
        preactHost,
      )
    },
    preactHost,
    expected,
  )

  const islandMountMs = await timeRenderToDom(
    () => {
      render(
        html`<div>${rows.map((r) => html`
          <${KpiStripIsland} ariaLabel="bench" cols=${cellsPerStrip} cells=${rowToCells(r, cellsPerStrip)} />
        `)}</div>`,
        islandHost,
      )
    },
    islandHost,
    expected,
  )

  return { preactMountMs, islandMountMs, rows }
}

// For updates we mutate every row, then measure how long until the new
// `total` value is reflected in *every* corresponding cell. We pick a
// per-row sentinel value (`row.total`) that's unique post-mutation and
// verify all of them landed in the DOM.
function timeUpdateToDom(
  renderFn: () => void,
  host: HTMLElement,
  expectedTexts: ReadonlyArray<string>,
  budgetMs = 5000,
): Promise<number> {
  return new Promise((resolve, reject) => {
    const start = performance.now()
    const deadline = start + budgetMs

    renderFn()

    const check = (): void => {
      // Cheap O(1) heuristic: textContent of host contains every sentinel.
      // For 500 rows this is ~500 substring scans of a multi-KB string, still
      // fast enough not to dominate the measurement.
      const text = host.textContent ?? ''
      const allFound = expectedTexts.every((t) => text.includes(t))
      const now = performance.now()
      if (allFound) {
        resolve(now - start)
        return
      }
      if (now > deadline) {
        reject(new Error(`update timed out waiting for sentinels`))
        return
      }
      requestAnimationFrame(check)
    }
    requestAnimationFrame(check)
  })
}

async function runUpdate(rows: SeedRow[], cellsPerStrip: number): Promise<{
  preactUpdateMs: number
  islandUpdateMs: number
}> {
  for (const row of rows) row.total += 1
  const sentinels = rows.map((r) => String(r.total))

  const preactUpdateMs = await timeUpdateToDom(
    () => {
      render(
        html`<div>${rows.map((r) => html`
          <${KpiStrip} ariaLabel="bench" cols=${cellsPerStrip}>
            ${rowToCells(r, cellsPerStrip).map((cell) => html`<${KpiCell} ...${cell} />`)}
          <//>
        `)}</div>`,
        preactHost,
      )
    },
    preactHost,
    sentinels,
  )

  const islandUpdateMs = await timeUpdateToDom(
    () => {
      render(
        html`<div>${rows.map((r) => html`
          <${KpiStripIsland} ariaLabel="bench" cols=${cellsPerStrip} cells=${rowToCells(r, cellsPerStrip)} />
        `)}</div>`,
        islandHost,
      )
    },
    islandHost,
    sentinels,
  )

  return { preactUpdateMs, islandUpdateMs }
}

async function runFullBench(label: string, count: number, cellsPerStrip: number, updateRounds = 3): Promise<BenchResult> {
  const mount = await runMount(count, cellsPerStrip)

  const preactUpdates: number[] = []
  const islandUpdates: number[] = []
  for (let i = 0; i < updateRounds; i += 1) {
    const u = await runUpdate(mount.rows, cellsPerStrip)
    preactUpdates.push(u.preactUpdateMs)
    islandUpdates.push(u.islandUpdateMs)
  }

  const result: BenchResult = {
    preactMountMs: mount.preactMountMs,
    islandMountMs: mount.islandMountMs,
    preactUpdateMs: preactUpdates,
    islandUpdateMs: islandUpdates,
  }
  reportResult(label, result, count, cellsPerStrip)
  return result
}

document.getElementById('run-mount')?.addEventListener('click', () => {
  const count = Number(countInput.value)
  const cellsPerStrip = Number(cellsInput.value)
  resultsEl.textContent = ''
  void runFullBench(`mount (n=${count})`, count, cellsPerStrip, 0)
})

document.getElementById('run-update')?.addEventListener('click', () => {
  const count = Number(countInput.value)
  const cellsPerStrip = Number(cellsInput.value)
  void runFullBench(`update (n=${count})`, count, cellsPerStrip, 3)
})

document.getElementById('run-clear')?.addEventListener('click', () => {
  clear()
  resultsEl.textContent = '(cleared)'
})

document.getElementById('run-warmup')?.addEventListener('click', async () => {
  resultsEl.textContent = 'warming up (3 silent rounds)...\n'
  const count = Number(countInput.value)
  const cellsPerStrip = Number(cellsInput.value)
  for (let i = 0; i < 3; i += 1) {
    await runMount(count, cellsPerStrip)
  }
  clear()
  resultsEl.textContent += 'warmup done. Now click "Mount + measure" or "Full suite".\n'
})

document.getElementById('run-suite')?.addEventListener('click', async () => {
  resultsEl.textContent = ''
  const cellsPerStrip = Number(cellsInput.value)
  for (const n of [10, 16, 50, 100, 250, 500]) {
    countInput.value = String(n)
    await runFullBench(`suite n=${n}`, n, cellsPerStrip, 3)
  }
})

// ── Sustained-update benchmark ──
//
// Models the realistic dashboard workload: 16 keepers (or domain rows)
// each emitting an SSE event burst that triggers a parent re-render.
// The naive "3 update samples" mode in the suite above misses what
// happens when update events keep landing while the previous one is
// still draining. This mode loops re-renders for a fixed window and
// records:
//   - throughput (updates/sec actually completed)
//   - frame budget impact (rAF callbacks observed during the window;
//     a healthy 60 Hz tab sees ~60 frames/sec → fewer = blocked frames)
//   - mean / p95 update latency
//
// We run the loop on each side **separately** (Preact first, then
// island) so they don't compete for the main thread. Otherwise the
// slower side would skew the faster side's measurement.

interface SustainedResult {
  side: 'preact' | 'island'
  windowMs: number
  updates: number
  framesObserved: number
  expectedFrames: number
  meanMs: number
  p95Ms: number
  maxMs: number
}

function frameCounter(windowMs: number): { stop: () => number } {
  let count = 0
  let stopped = false
  const tick = (): void => {
    if (stopped) return
    count += 1
    requestAnimationFrame(tick)
  }
  requestAnimationFrame(tick)
  return {
    stop: () => {
      stopped = true
      return count
    },
  }
}

function p95(values: number[]): number {
  if (values.length === 0) return NaN
  const sorted = [...values].sort((a, b) => a - b)
  const idx = Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))
  return sorted[idx] ?? NaN
}

async function runSustainedSide(
  side: 'preact' | 'island',
  rows: SeedRow[],
  cellsPerStrip: number,
  windowMs: number,
): Promise<SustainedResult> {
  const host = side === 'preact' ? preactHost : islandHost
  const expectedFrames = Math.round((windowMs / 1000) * 60)
  const fc = frameCounter(windowMs)

  const samples: number[] = []
  const start = performance.now()
  const deadline = start + windowMs
  let updates = 0

  while (performance.now() < deadline) {
    for (const r of rows) r.total += 1
    const sentinels = rows.map((r) => String(r.total))
    const renderFn = side === 'preact'
      ? () => render(
          html`<div>${rows.map((r) => html`
            <${KpiStrip} ariaLabel="bench" cols=${cellsPerStrip}>
              ${rowToCells(r, cellsPerStrip).map((cell) => html`<${KpiCell} ...${cell} />`)}
            <//>
          `)}</div>`,
          host,
        )
      : () => render(
          html`<div>${rows.map((r) => html`
            <${KpiStripIsland} ariaLabel="bench" cols=${cellsPerStrip} cells=${rowToCells(r, cellsPerStrip)} />
          `)}</div>`,
          host,
        )

    try {
      const ms = await timeUpdateToDom(renderFn, host, sentinels, 1000)
      samples.push(ms)
      updates += 1
    } catch {
      // Drop missed updates; loop will re-render the next iteration.
      break
    }
  }

  const framesObserved = fc.stop()
  const mean = samples.length ? samples.reduce((a, b) => a + b, 0) / samples.length : NaN

  return {
    side,
    windowMs,
    updates,
    framesObserved,
    expectedFrames,
    meanMs: mean,
    p95Ms: p95(samples),
    maxMs: samples.length ? Math.max(...samples) : NaN,
  }
}

function reportSustained(label: string, n: number, preactR: SustainedResult, islandR: SustainedResult): void {
  const block = [
    `=== ${label} (n=${n} strips, window=${preactR.windowMs}ms) ===`,
    `Preact:  ${preactR.updates.toString().padStart(4)} updates,  frames ${preactR.framesObserved}/${preactR.expectedFrames}  ` +
      `mean=${preactR.meanMs.toFixed(2)} p95=${preactR.p95Ms.toFixed(2)} max=${preactR.maxMs.toFixed(2)} ms`,
    `Solid:   ${islandR.updates.toString().padStart(4)} updates,  frames ${islandR.framesObserved}/${islandR.expectedFrames}  ` +
      `mean=${islandR.meanMs.toFixed(2)} p95=${islandR.p95Ms.toFixed(2)} max=${islandR.maxMs.toFixed(2)} ms`,
    `  → throughput ratio Solid/Preact = ${(islandR.updates / Math.max(1, preactR.updates)).toFixed(2)}`,
    `  → frame retention Preact ${((preactR.framesObserved / preactR.expectedFrames) * 100).toFixed(0)}%, Solid ${((islandR.framesObserved / islandR.expectedFrames) * 100).toFixed(0)}%`,
    '',
  ]
  resultsEl.textContent = (resultsEl.textContent ?? '') + block.join('\n') + '\n'
  console.log(block.join('\n'))
}

document.getElementById('run-sustained')?.addEventListener('click', async () => {
  resultsEl.textContent = 'sustained: warmup mount n=16...\n'
  const n = 16
  const cellsPerStrip = Number(cellsInput.value)
  const mount = await runMount(n, cellsPerStrip)

  // Run each side for 5s separately so the slow one doesn't poison
  // the fast one's frame counter.
  const windowMs = 5000
  resultsEl.textContent += `Running Preact side ${windowMs}ms...\n`
  const preactR = await runSustainedSide('preact', mount.rows, cellsPerStrip, windowMs)
  resultsEl.textContent += `Running Solid side ${windowMs}ms...\n`
  const islandR = await runSustainedSide('island', mount.rows, cellsPerStrip, windowMs)

  reportSustained(`sustained 5s`, n, preactR, islandR)
})

// "Keeper-shape spike": 16 keepers each emit a burst of ~60 updates
// (one per second over a minute, compressed). Measures cumulative cost
// of a typical hour of dashboard idle-watching.
document.getElementById('run-keeper-shape')?.addEventListener('click', async () => {
  resultsEl.textContent = ''
  const n = 16
  const cellsPerStrip = Number(cellsInput.value)
  const mount = await runMount(n, cellsPerStrip)

  const burstUpdates = 60
  const preactSamples: number[] = []
  const islandSamples: number[] = []

  for (let i = 0; i < burstUpdates; i += 1) {
    const u = await runUpdate(mount.rows, cellsPerStrip)
    preactSamples.push(u.preactUpdateMs)
    islandSamples.push(u.islandUpdateMs)
  }

  const ps = preactSamples
  const is_ = islandSamples
  const block = [
    `=== keeper-shape spike (n=${n}, ${burstUpdates} updates each side) ===`,
    `Preact: total ${ps.reduce((a, b) => a + b, 0).toFixed(0)}ms, mean ${(ps.reduce((a, b) => a + b, 0) / ps.length).toFixed(2)}ms, p95 ${p95(ps).toFixed(2)}ms, max ${Math.max(...ps).toFixed(2)}ms`,
    `Solid:  total ${is_.reduce((a, b) => a + b, 0).toFixed(0)}ms, mean ${(is_.reduce((a, b) => a + b, 0) / is_.length).toFixed(2)}ms, p95 ${p95(is_).toFixed(2)}ms, max ${Math.max(...is_).toFixed(2)}ms`,
    '',
  ]
  resultsEl.textContent = block.join('\n') + '\n'
  console.log(block.join('\n'))
})

// ── Sync-mount spike (RFC 0017 §7d) ──
//
// Compares the shipping island wrapper (useEffect-based) against
// `KpiStripIslandSync`, which moves the Solid mount into a Preact ref
// callback (commit-phase synchronous) and the prop sync into
// `useLayoutEffect`. If the spike's hypothesis holds, the ~30 ms
// useEffect overhead disappears and the variant beats the shipping
// island at the same n.

const syncHost = document.getElementById('sync-host') as HTMLElement

async function timeSyncRender(
  rows: SeedRow[],
  cellsPerStrip: number,
  expectedSentinels: ReadonlyArray<string>,
): Promise<number> {
  return timeUpdateToDom(
    () => {
      render(
        html`<div>${rows.map((r) => html`
          <${KpiStripIslandSync} ariaLabel="bench" cols=${cellsPerStrip} cells=${rowToCells(r, cellsPerStrip)} />
        `)}</div>`,
        syncHost,
      )
    },
    syncHost,
    expectedSentinels,
  )
}

document.getElementById('run-spike-sync')?.addEventListener('click', async () => {
  resultsEl.textContent = 'sync-mount spike: warmup...\n'
  const n = 16
  const cellsPerStrip = Number(cellsInput.value)
  const burstUpdates = 60

  // Warmup
  for (let i = 0; i < 3; i += 1) {
    await runMount(n, cellsPerStrip)
    render(null, syncHost)
  }

  resultsEl.textContent = ''

  // ─── Mount comparison ───
  const rows = makeSeed(n)
  const expected = n * cellsPerStrip

  render(null, preactHost)
  const preactMountMs = await timeRenderToDom(
    () => render(
      html`<div>${rows.map((r) => html`
        <${KpiStrip} ariaLabel="bench" cols=${cellsPerStrip}>
          ${rowToCells(r, cellsPerStrip).map((cell) => html`<${KpiCell} ...${cell} />`)}
        <//>
      `)}</div>`,
      preactHost,
    ),
    preactHost,
    expected,
  )

  render(null, islandHost)
  const islandMountMs = await timeRenderToDom(
    () => render(
      html`<div>${rows.map((r) => html`
        <${KpiStripIsland} ariaLabel="bench" cols=${cellsPerStrip} cells=${rowToCells(r, cellsPerStrip)} />
      `)}</div>`,
      islandHost,
    ),
    islandHost,
    expected,
  )

  render(null, syncHost)
  const syncMountMs = await timeRenderToDom(
    () => render(
      html`<div>${rows.map((r) => html`
        <${KpiStripIslandSync} ariaLabel="bench" cols=${cellsPerStrip} cells=${rowToCells(r, cellsPerStrip)} />
      `)}</div>`,
      syncHost,
    ),
    syncHost,
    expected,
  )

  // ─── Burst update comparison (60 sequential re-renders) ───
  const preactSamples: number[] = []
  const islandSamples: number[] = []
  const syncSamples: number[] = []
  for (let i = 0; i < burstUpdates; i += 1) {
    for (const r of rows) r.total += 1
    const sentinels = rows.map((r) => String(r.total))

    preactSamples.push(await timeUpdateToDom(
      () => render(
        html`<div>${rows.map((r) => html`
          <${KpiStrip} ariaLabel="bench" cols=${cellsPerStrip}>
            ${rowToCells(r, cellsPerStrip).map((cell) => html`<${KpiCell} ...${cell} />`)}
          <//>
        `)}</div>`,
        preactHost,
      ),
      preactHost,
      sentinels,
    ))

    islandSamples.push(await timeUpdateToDom(
      () => render(
        html`<div>${rows.map((r) => html`
          <${KpiStripIsland} ariaLabel="bench" cols=${cellsPerStrip} cells=${rowToCells(r, cellsPerStrip)} />
        `)}</div>`,
        islandHost,
      ),
      islandHost,
      sentinels,
    ))

    syncSamples.push(await timeSyncRender(rows, cellsPerStrip, sentinels))
  }

  const summary = (samples: number[]): string => {
    const total = samples.reduce((a, b) => a + b, 0)
    const mean = total / samples.length
    return `total=${total.toFixed(0)}ms mean=${mean.toFixed(2)}ms p95=${p95(samples).toFixed(2)}ms max=${Math.max(...samples).toFixed(2)}ms`
  }

  const block = [
    `=== sync-mount spike (n=${n}, ${burstUpdates} updates) ===`,
    `Mount→DOM:`,
    `  Preact KpiStrip:           ${preactMountMs.toFixed(2)} ms`,
    `  Solid useEffect island:    ${islandMountMs.toFixed(2)} ms`,
    `  Solid sync-mount island:   ${syncMountMs.toFixed(2)} ms`,
    `  delta sync vs useEffect:   ${(islandMountMs - syncMountMs).toFixed(2)} ms saved`,
    `  delta sync vs Preact:      ${(syncMountMs - preactMountMs).toFixed(2)} ms (positive = sync slower than Preact)`,
    ``,
    `Update→DOM (${burstUpdates} samples):`,
    `  Preact KpiStrip:           ${summary(preactSamples)}`,
    `  Solid useEffect island:    ${summary(islandSamples)}`,
    `  Solid sync-mount island:   ${summary(syncSamples)}`,
    `  throughput sync/Preact:    ${(syncSamples.reduce((a, b) => a + b, 0) / preactSamples.reduce((a, b) => a + b, 0)).toFixed(2)} (1.0 = parity)`,
    `  throughput sync/useEffect: ${(syncSamples.reduce((a, b) => a + b, 0) / islandSamples.reduce((a, b) => a + b, 0)).toFixed(2)}`,
    '',
  ]
  resultsEl.textContent = block.join('\n') + '\n'
  console.log(block.join('\n'))
})
