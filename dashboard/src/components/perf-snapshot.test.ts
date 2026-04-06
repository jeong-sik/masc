import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

void vi

async function flushUi(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

async function loadPanel(fetchDashboardPerf: () => Promise<unknown>) {
  vi.resetModules()
  vi.doMock('../api', () => ({
    fetchDashboardPerf,
  }))
  vi.doMock('./common/time-ago', () => ({
    TimeAgo: ({ timestamp }: { timestamp: string }) => html`<span>${timestamp}</span>`,
  }))
  return import('./perf-snapshot')
}

describe('PerfSnapshotPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
    vi.resetModules()
    vi.doUnmock('../api')
    vi.doUnmock('./common/time-ago')
  })

  it('renders empty-state guidance when no benchmark artifact exists', async () => {
    const fetchDashboardPerf = vi.fn().mockResolvedValue({
      status: 'empty',
      generated_at: '2026-03-31T05:00:00Z',
      benchmarks: [],
      comparison: null,
      candidate_dirs: ['benchmarks/results'],
      message: 'No benchmark artifacts found',
    })

    const { PerfSnapshotPanel } = await loadPanel(fetchDashboardPerf)
    render(html`<${PerfSnapshotPanel} />`, container)
    await flushUi()

    expect(fetchDashboardPerf).toHaveBeenCalledTimes(1)
    expect(container.textContent).toContain('Perf Snapshot')
    expect(container.textContent).toContain('benchmark artifact가 아직 없습니다')
    expect(container.textContent).toContain('benchmark.sh')
  })

  it('renders benchmark highlights and diff badges for ok status', async () => {
    const fetchDashboardPerf = vi.fn().mockResolvedValue({
      status: 'ok',
      generated_at: '2026-03-31T05:00:00Z',
      benchmarks: [],
      source: {
        results_dir: 'benchmarks/results',
        result_file: 'benchmarks/results/results_20260331_140000.csv',
        baseline_file: 'benchmarks/results/results_20260331_130000.csv',
      },
      latest_run: {
        started_at: '2026-03-31T05:00:00Z',
      },
      highlights: {
        session_init: {
          benchmark: 'mcp_session_init',
          avg_ms: 7,
          p50_ms: 7,
          p95_ms: 9,
          max_ms: 12,
          notes: 'session',
          note_tags: {},
        },
        worst_live_mcp: {
          benchmark: 'mcp_read_status',
          avg_ms: 8,
          p50_ms: 7,
          p95_ms: 66,
          max_ms: 88,
          notes: 'source=live',
          note_tags: { source: 'live' },
        },
        runtime_status: {
          benchmark: 'oas_runtime_status',
          avg_ms: 111,
          p50_ms: 110,
          p95_ms: 132,
          max_ms: 150,
          notes: 'configured_capacity=16;healthy_runtime_count=4',
          note_tags: { configured_capacity: '16', healthy_runtime_count: '4' },
        },
        runtime_single: {
          benchmark: 'oas_runtime_single',
          avg_ms: 820,
          p50_ms: 805,
          p95_ms: 1010,
          max_ms: 1160,
          notes: 'measured_ceiling=1',
          note_tags: { measured_ceiling: '1' },
        },
      },
      comparison: {
        baseline_file: 'benchmarks/results/results_20260331_130000.csv',
        verdict_counts: {
          improved: 1,
          stable: 2,
          mixed: 0,
          regressed: 1,
        },
        top_changes: [
          {
            benchmark: 'oas_runtime_single',
            avg_delta_ms: -180,
            avg_delta_pct: -18,
            p95_delta_ms: -290,
            p95_delta_pct: -22.3,
            max_delta_ms: -190,
            verdict: 'improved',
          },
        ],
      },
    })

    const { PerfSnapshotPanel } = await loadPanel(fetchDashboardPerf)
    render(html`<${PerfSnapshotPanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Session Init')
    expect(container.textContent).toContain('Worst MCP p95')
    expect(container.textContent).toContain('Runtime Avg')
    expect(container.textContent).toContain('Runtime Status')
    expect(container.textContent).toContain('improved')
    expect(container.textContent).toContain('regressed')
    expect(container.textContent).toContain('Benchmark p95')
    expect(container.textContent).toContain('Delta Magnitude')
    expect(container.textContent).toContain('oas_runtime_single')
    expect(container.textContent).toContain('measured ceiling 1')
  })

  it('renders request errors', async () => {
    const fetchDashboardPerf = vi.fn().mockRejectedValue(new Error('perf endpoint failed'))

    const { PerfSnapshotPanel } = await loadPanel(fetchDashboardPerf)
    render(html`<${PerfSnapshotPanel} />`, container)
    await flushUi()

    expect(fetchDashboardPerf).toHaveBeenCalledTimes(1)
    expect(container.textContent).toContain('perf endpoint failed')
  })
})
