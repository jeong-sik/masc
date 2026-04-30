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
  for (const n of [10, 50, 100, 250, 500]) {
    countInput.value = String(n)
    await runFullBench(`suite n=${n}`, n, cellsPerStrip, 3)
  }
})
