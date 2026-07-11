import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { h } from 'preact'
import { act, cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { LogEntry } from '../api/dashboard'
import {
  deltaMergeCap,
  logDiagnosticCause,
  mergeLogEntries,
  summarizeLogWindow,
} from './logs'

function entry(overrides: Partial<LogEntry>): LogEntry {
  return {
    seq: 1,
    ts: '2026-05-14T00:00:00Z',
    level: 'INFO',
    source: 'structured',
    module: 'Keeper',
    message: 'ok',
    keeper_name: null,
    turn_id: null,
    details: null,
    category: null,
    ...overrides,
  }
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(innerResolve => {
    resolve = innerResolve
  })
  return { promise, resolve }
}

async function loadLogs(
  fetchLogs: ReturnType<typeof vi.fn>,
  providerMocks?: {
    fetchProviderLogsCatalog?: ReturnType<typeof vi.fn>
    fetchProviderLogTail?: ReturnType<typeof vi.fn>
  },
) {
  const fetchProviderLogsCatalog = providerMocks?.fetchProviderLogsCatalog
    ?? vi.fn().mockResolvedValue({ providers: [] })
  const fetchProviderLogTail = providerMocks?.fetchProviderLogTail
    ?? vi.fn().mockResolvedValue({ provider: { id: 'none', display_name: 'none', protocol: 'none' }, entries: [] })
  vi.resetModules()
  vi.doMock('../api/dashboard.js', () => ({
    fetchLogs,
    fetchProviderLogsCatalog,
    fetchProviderLogTail,
  }))
  return import('./logs')
}

describe('log diagnostics', () => {
  it('does not infer diagnostic causes from raw message text', () => {
    expect(
      logDiagnosticCause(
        entry({
          level: 'WARN',
          message:
            'keeper_llm_bridge: OAS execution timed out after 300.0s (budget=300s)',
        }),
      ),
    ).toBeNull()

    expect(
      logDiagnosticCause(
        entry({
          level: 'ERROR',
          message:
            'all runtimes exhausted: Runtime attempt liveness guard killed runtime lane glm-coding-with-spark: inter_chunk_idle',
        }),
      ),
    ).toBeNull()
  })

  it('requires structured details for keeper telemetry and registry causes', () => {
    expect(
      logDiagnosticCause(
        entry({
          level: 'INFO',
          message:
            'keeper:analyst after_turn usage telemetry unavailable runtime_lane=runtime reasons=zero_token_usage_reported input=0 output=0 context_max=200000',
        }),
      ),
    ).toBeNull()

    expect(
      logDiagnosticCause(
        entry({
          level: 'WARN',
          message:
            'registry: orphan threshold breached name=analyst base_path=/Users/dancer/me drops=5 window=60s',
        }),
      ),
    ).toBeNull()
  })

  it('uses structured event details as diagnostic causes', () => {
    expect(
      logDiagnosticCause(
        entry({
          level: 'WARN',
          message: 'registry warning',
          details: { event: 'registry_orphan_threshold' },
        }),
      ),
    ).toBe('registry_orphan_threshold')
  })

  it('prefers failure envelope cause codes and summarizes the current window', () => {
    const entries = [
      entry({
        seq: 3,
        level: 'ERROR',
        module: 'Keeper',
        message: 'keeper provider timeout',
        details: {
          failure_envelope: {
            surface: 'keeper_oas_bridge',
            entity_kind: 'oas_execution',
            entity_id: null,
            cause_code: 'provider_timeout',
            severity: 'bad',
            summary: 'Provider execution timed out',
            recoverability: 'operator_action_required',
            operator_action: 'inspect_provider_stream',
            evidence_ref: { timeout_sec: 300 },
          },
        },
      }),
      entry({
        seq: 2,
        level: 'WARN',
        module: 'Task',
        message: 'unstructured watchdog warning',
      }),
      entry({
        seq: 1,
        level: 'INFO',
        module: 'Keeper',
        message: 'normal',
      }),
    ]

    const summary = summarizeLogWindow(entries)
    expect(summary.errors).toBe(1)
    expect(summary.warnings).toBe(1)
    expect(summary.failureEnvelopes).toBe(1)
    expect(summary.topCauses).toContainEqual({ cause: 'provider_timeout', count: 1 })
    expect(summary.topCauses).toHaveLength(1)
    expect(summary.topModules[0]).toEqual({ module: 'Keeper', count: 2 })
  })
})

describe('deltaMergeCap (load-older erosion guard)', () => {
  it('keeps a fixed newest-N sliding window when not paged', () => {
    const current = [entry({ seq: 10 }), entry({ seq: 9 })]
    const incoming = [entry({ seq: 11 })]
    // un-paged: cap stays at the base limit regardless of how many rows exist,
    // so old rows roll off and memory stays bounded.
    expect(deltaMergeCap(current, incoming, false, 200)).toBe(200)
    expect(deltaMergeCap(current, incoming, false, 2)).toBe(2)
  })

  it('grows the cap to fit current rows plus genuinely-new rows when paged', () => {
    const current = [entry({ seq: 10 }), entry({ seq: 9 }), entry({ seq: 8 })]
    const incoming = [entry({ seq: 11 })] // 1 fresh
    // paged: cap must cover every currently shown row (3) + the fresh row (1).
    expect(deltaMergeCap(current, incoming, true, 2)).toBe(4)
  })

  it('counts only non-overlapping incoming rows as fresh when paged', () => {
    const current = [entry({ seq: 10 }), entry({ seq: 9 })]
    // seq 10 overlaps the current window; only seq 11 is genuinely new.
    const incoming = [entry({ seq: 11 }), entry({ seq: 10 })]
    expect(deltaMergeCap(current, incoming, true, 2)).toBe(3)
  })

  it('prevents the delta poll from evicting paged-in older rows over multiple cycles', () => {
    // Reproduces the erosion: base limit 2, operator paged a third (older) row
    // in (seq 8). Each delta poll appends one newer row. A cap that only covered
    // the currently shown rows (limit == 2, or the pre-deltaMergeCap
    // max(displayCap, limit) shape) would let the newest-first slice drop seq 8.
    let current = [entry({ seq: 10 }), entry({ seq: 9 }), entry({ seq: 8, message: 'paged older' })]
    for (const fresh of [11, 12, 13]) {
      const incoming = [entry({ seq: fresh, message: `delta ${fresh}` })]
      const cap = deltaMergeCap(current, incoming, true, 2)
      current = mergeLogEntries(current, incoming, cap)
      // the paged-in oldest row must survive every cycle
      expect(current.some(e => e.seq === 8)).toBe(true)
    }
    // after 3 delta cycles all rows are retained, none evicted
    expect(current.map(e => e.seq)).toEqual([13, 12, 11, 10, 9, 8])
  })
})

describe('LogViewer Code links', () => {
  afterEach(() => {
    cleanup()
    vi.useRealTimers()
    vi.clearAllMocks()
    vi.resetModules()
    vi.doUnmock('../api/dashboard.js')
    window.location.hash = ''
  })

  it('preserves delta rows when an older page resolves after auto-refresh', async () => {
    vi.useFakeTimers()
    const olderPage = deferred<{ total: number; entries: LogEntry[] }>()
    const fetchLogs = vi.fn((opts?: { since_seq?: number; before_seq?: number }) => {
      if (typeof opts?.before_seq === 'number') {
        return olderPage.promise
      }
      if (typeof opts?.since_seq === 'number') {
        return Promise.resolve({
          total: 3,
          entries: [entry({ seq: 11, module: 'Keeper', message: 'delta fresh' })],
        })
      }
      return Promise.resolve({
        total: 2,
        entries: [
          entry({ seq: 10, module: 'Keeper', message: 'newest visible' }),
          entry({ seq: 9, module: 'Keeper', message: 'oldest visible' }),
        ],
      })
    })
    const { LogViewer } = await loadLogs(fetchLogs)
    const { container } = render(h(LogViewer, {}))

    await waitFor(() => expect(container.textContent).toContain('oldest visible'))
    const loadOlderButton = container.querySelector(
      '[data-testid="logs-load-older"]',
    ) as HTMLButtonElement | null
    expect(loadOlderButton).not.toBeNull()

    await act(async () => {
      fireEvent.click(loadOlderButton!)
    })
    await waitFor(() =>
      expect(fetchLogs).toHaveBeenCalledWith(expect.objectContaining({ before_seq: 9 })),
    )

    await act(async () => {
      await vi.advanceTimersByTimeAsync(3000)
    })
    await waitFor(() => expect(container.textContent).toContain('delta fresh'))

    await act(async () => {
      olderPage.resolve({
        total: 3,
        entries: [entry({ seq: 8, module: 'Keeper', message: 'older page' })],
      })
      await olderPage.promise
    })

    await waitFor(() => {
      expect(container.textContent).toContain('delta fresh')
      expect(container.textContent).toContain('newest visible')
      expect(container.textContent).toContain('oldest visible')
      expect(container.textContent).toContain('older page')
    })
    expect(fetchLogs).toHaveBeenCalledWith(expect.objectContaining({ since_seq: 10 }))
  })

  it('links safe structured log file details back to the Code IDE route', async () => {
    const fetchLogs = vi.fn().mockResolvedValue({
      total: 1,
      generated_at_iso: '2026-05-15T01:00:00Z',
      dashboard_surface: '/api/v1/dashboard/logs',
      source: 'masc_log_ring',
      retention: {
        scope: 'dashboard_logs',
        durable_store: '/Users/dancer/me/.masc/logs/system_log_2026-05-15.jsonl',
      },
      latest_seq: 1,
      entries: [{
        seq: 1,
        ts: '2026-05-14T00:00:00Z',
        level: 'INFO',
        source: 'structured',
        module: 'keeper_tool',
        message: 'read file',
        details: { file_path: 'lib/runtime.ml', line: 12 },
      }],
    })
    const { LogViewer } = await loadLogs(fetchLogs)
    const { container } = render(h(LogViewer, {}))

    await waitFor(() =>
      expect(container.querySelector('[data-testid="logs-code-link"]')).not.toBeNull(),
    )
    const codeLink = container.querySelector('[data-testid="logs-code-link"]') as HTMLButtonElement
    expect(codeLink.textContent).toBe('Code')
    expect(codeLink.getAttribute('title')).toBe('Code lib/runtime.ml:12')
    const provenance = container.querySelector('[data-testid="logs-provenance"]') as HTMLElement
    expect(provenance.textContent).toContain('masc_log_ring')
    expect(provenance.textContent).toContain('dashboard_logs')
    expect(provenance.textContent).toContain('system_log_2026-05-15.jsonl')

    codeLink.click()
    expect(window.location.hash).toBe(
      '#code?section=ide-shell&view=source&file=lib%2Fruntime.ml&line=12&surface=Log&label=keeper_tool&source_id=log%3A1',
    )
  })

  it('renders enabled provider log tail from the configured provider path', async () => {
    const fetchLogs = vi.fn().mockResolvedValue({ total: 0, entries: [] })
    const fetchProviderLogsCatalog = vi.fn().mockResolvedValue({
      providers: [{
        id: 'ollama',
        display_name: 'Ollama Local',
        protocol: 'ollama-http',
        enabled: true,
        path: '~/.ollama/logs/server.log',
        resolved_path: '/Users/dancer/.ollama/logs/server.log',
        default_lines: 200,
        max_bytes: 1048576,
      }],
    })
    const fetchProviderLogTail = vi.fn().mockResolvedValue({
      provider: {
        id: 'ollama',
        display_name: 'Ollama Local',
        protocol: 'ollama-http',
      },
      entries: [
        { line: 1, text: 'aborting completion request due to client closing the connection' },
      ],
    })

    const { LogViewer } = await loadLogs(fetchLogs, {
      fetchProviderLogsCatalog,
      fetchProviderLogTail,
    })
    const { container } = render(h(LogViewer, {}))

    await waitFor(() =>
      expect(container.querySelector('[data-testid="provider-log-tail"]')?.textContent)
        .toContain('client closing the connection'),
    )
    expect(fetchProviderLogTail).toHaveBeenCalledWith('ollama', { lines: 200 })
    expect(container.textContent).toContain('server.log')
  })

  // RFC-0079 removed the dropped-rows surface. parseLogsResponse now
  // throws LogsSchemaDriftError instead of silently dropping bad rows,
  // so there is no "parser dropped N rows" state to render here.

  it('renders v2 surface marker classes for CSS scoping', async () => {
    const fetchLogs = vi.fn().mockResolvedValue({
      total: 1,
      entries: [{
        seq: 1,
        ts: '2026-05-14T00:00:00Z',
        level: 'INFO',
        source: 'structured',
        module: 'keeper_tool',
        message: 'read file',
        details: { file_path: 'lib/runtime.ml', line: 12 },
      }],
    })
    const fetchProviderLogsCatalog = vi.fn().mockResolvedValue({
      providers: [{
        id: 'ollama',
        display_name: 'Ollama Local',
        protocol: 'ollama-http',
        enabled: true,
        path: '~/.ollama/logs/server.log',
        resolved_path: '/Users/dancer/.ollama/logs/server.log',
        default_lines: 200,
        max_bytes: 1048576,
      }],
    })
    const fetchProviderLogTail = vi.fn().mockResolvedValue({
      provider: { id: 'ollama', display_name: 'Ollama Local', protocol: 'ollama-http' },
      entries: [{ line: 1, text: 'tail line' }],
    })
    const { LogViewer } = await loadLogs(fetchLogs, { fetchProviderLogsCatalog, fetchProviderLogTail })
    const { container } = render(h(LogViewer, {}))

    await waitFor(() => expect(container.querySelector('.v2-logs-surface')).not.toBeNull())
    expect(container.querySelector('.v2-logs-panel')).not.toBeNull()
    expect(container.querySelector('.v2-logs-toolbar')).not.toBeNull()
    expect(container.querySelector('[data-testid="logs-filter-tool"]')).not.toBeNull()
    expect(container.querySelector('.v2-logs-table-header')).not.toBeNull()
    expect(container.querySelector('.v2-logs-row')).not.toBeNull()
    expect(container.querySelector('[data-testid="logs-row"]')?.getAttribute('data-log-seq')).toBe('1')
    expect(container.querySelector('.v2-logs-summary')).not.toBeNull()
    expect(container.querySelector('.v2-logs-provider-panel')).not.toBeNull()
    const diagnostics = container.querySelector('[data-testid="logs-provider-diagnostics"]') as HTMLDetailsElement
    expect(diagnostics).not.toBeNull()
    expect(diagnostics.open).toBe(false)
    expect(diagnostics.querySelector('summary')?.textContent).toContain('Provider diagnostics')
  })

  it('does not render Code links for unsafe absolute log file paths', async () => {
    const fetchLogs = vi.fn().mockResolvedValue({
      total: 1,
      entries: [{
        seq: 2,
        ts: '2026-05-14T00:00:00Z',
        level: 'INFO',
        source: 'structured',
        module: 'keeper_tool',
        message: 'read file',
        details: { file_path: '/tmp/runtime.ml', line: 12 },
      }],
    })
    const { LogViewer } = await loadLogs(fetchLogs)
    const { container } = render(h(LogViewer, {}))

    await waitFor(() => expect(container.textContent).toContain('read file'))
    expect(container.querySelector('[data-testid="logs-code-link"]')).toBeNull()
  })

  it('links nested log evidence into operational IDE routes', async () => {
    const fetchLogs = vi.fn().mockResolvedValue({
      total: 1,
      entries: [{
        seq: 3,
        ts: '2026-05-14T00:00:00Z',
        level: 'WARN',
        source: 'structured',
        module: 'keeper_tool',
        message: 'tool warning',
        details: {
          context: {
            goal_id: 'goal-runtime',
            task_id: 'task-runtime',
            board_post_id: 'post-1',
            comment_id: 'comment-1',
          },
          failure_envelope: {
            evidence_ref: {
              file_path: 'lib/runtime.ml',
              line_start: 8,
              pr_number: 15008,
              branch: 'feat/runtime',
              log_id: 'turn-8',
              session_id: 'sess-nested',
              operation_id: 'op-nested',
              worker_run_id: 'wr-nested',
            },
          },
        },
      }],
    })
    const { LogViewer } = await loadLogs(fetchLogs)
    const { container } = render(h(LogViewer, {}))

    await waitFor(() => expect(container.textContent).toContain('tool warning'))
    const routeLinks = [...container.querySelectorAll<HTMLButtonElement>('.logs-route-link')]
    expect(routeLinks.map(link => link.textContent)).toEqual([
      'Code',
      'Goal',
      'Task',
      'Board',
      'Comment',
      'PR',
      'Git',
      'Log',
      'Telemetry',
    ])

    routeLinks.find(link => link.textContent === 'Code')?.click()
    expect(window.location.hash).toBe('#code?section=ide-shell&view=source&file=lib%2Fruntime.ml&line=8&surface=Log&label=keeper_tool&source_id=log%3A3')

    routeLinks.find(link => link.textContent === 'Telemetry')?.click()
    expect(window.location.hash).toBe('#monitoring?section=fleet-health&view=event-log&session_id=sess-nested&operation_id=op-nested&worker_run_id=wr-nested&q=turn-8')
  })
  it('filters rows by kind chips and keeps kind-aware details for toolbar view', async () => {
    const fetchLogs = vi.fn().mockResolvedValue({
      total: 3,
      generated_at_iso: '2026-05-15T01:00:00Z',
      dashboard_surface: '/api/v1/dashboard/logs',
      source: 'masc_log_ring',
      retention: {
        scope: 'dashboard_logs',
        durable_store: '/Users/dancer/me/.masc/logs/system_log_2026-05-15.jsonl',
      },
      latest_seq: 3,
      entries: [
        entry({
          seq: 1,
          ts: '2026-05-14T00:00:00Z',
          level: 'INFO',
          module: 'keeper_tool',
          category: 'tool',
          message: 'tool event',
          details: {
            tool_name: 'fs.ls',
            outcome: 'ok',
            latency_ms: 128,
            namespace: 'filesystem',
          },
        }),
        entry({
          seq: 2,
          ts: '2026-05-14T00:00:01Z',
          level: 'INFO',
          module: 'keeper_turn',
          category: 'routine',
          turn_id: 2,
          message: 'turn event',
          details: {
            model: 'gpt-4o-mini',
            tools_used: ['planner', 'coder'],
            stop_reason: 'stop_reason',
            duration_ms: 321,
          },
        }),
        entry({
          seq: 3,
          ts: '2026-05-14T00:00:02Z',
          level: 'WARN',
          module: 'keeper_fsm',
          category: 'fsm',
          message: 'lifecycle event',
          details: {
            from: 'idle',
            to: 'running',
            trigger: 'wake',
          },
        }),
      ],
    })

    const { LogViewer } = await loadLogs(fetchLogs)
    const { container } = render(h(LogViewer, {}))

    await waitFor(() => expect(container.textContent).toContain('tool event'))
    expect(container.textContent).toContain('turn event')
    expect(container.textContent).toContain('lifecycle event')
    expect(container.querySelector('.v2-logs-live')?.textContent).toContain('masc-mcp · 3s polling')

    const toolChip = container.querySelector('[data-testid="logs-filter-tool"]') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(toolChip)
    })
    await waitFor(() => expect(container.textContent).toContain('tool event'))
    expect(container.textContent).not.toContain('turn event')
    expect(container.textContent).not.toContain('lifecycle event')

    const turnChip = container.querySelector('[data-testid="logs-filter-turn"]') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(turnChip)
    })
    await waitFor(() => expect(container.textContent).toContain('turn event'))
    expect(container.textContent).not.toContain('tool event')
    expect(container.textContent).not.toContain('lifecycle event')

    const lifecycleChip = container.querySelector('[data-testid="logs-filter-lifecycle"]') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(lifecycleChip)
    })
    await waitFor(() => expect(container.textContent).toContain('lifecycle event'))
    expect(container.textContent).not.toContain('tool event')
    expect(container.textContent).not.toContain('turn event')

    const allChip = container.querySelector('[data-testid="logs-filter-all"]') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(allChip)
    })
    await waitFor(() => expect(container.textContent).toContain('tool event'))
    expect(container.textContent).toContain('turn event')
    expect(container.textContent).toContain('lifecycle event')

    // Rows render newest-seq-first (sortLogEntries: b.seq - a.seq), so the tool
    // entry (seq 1) is the last row, not the first. Select it by its kind marker.
    const toolRow = [...container.querySelectorAll('[data-testid="logs-row"]')].find((row: Element) => {
      const rowKind = row.getAttribute('data-kind')
      const cellKind = row.querySelector('.v2-logs-kind')?.getAttribute('data-kind')
      return rowKind === 'tool' || cellKind === 'tool'
    }) as HTMLDivElement
    expect(toolRow).not.toBeNull()
    fireEvent.click(toolRow.querySelector('.v2-logs-line') as Element)
    await waitFor(() =>
      expect((toolRow as HTMLDivElement).querySelector('.v2-logs-kind-grid')?.textContent).toContain('tool'),
    )
  })
})

describe('LogViewer kind column', () => {
  afterEach(() => {
    cleanup()
    vi.useRealTimers()
    vi.clearAllMocks()
    vi.resetModules()
    vi.doUnmock('../api/dashboard.js')
    window.location.hash = ''
  })

  it('renders the logs surface with the kind column header and a kind cell per row', async () => {
    const fetchLogs = vi.fn().mockResolvedValue({
      total: 1,
      entries: [
        entry({
          seq: 42,
          level: 'INFO',
          source: 'structured',
          module: 'keeper_tool',
          message: 'read file',
          category: 'tool',
          details: { tool_name: 'tool_read_file', file_path: 'lib/runtime.ml' },
        }),
      ],
    })
    const { LogViewer } = await loadLogs(fetchLogs)
    const { container } = render(h(LogViewer, {}))

    await waitFor(() => expect(container.textContent).toContain('read file'))

    // The table header carries the kind ("유형") column the --v2-logs-cols grid sizes.
    const header = container.querySelector('.v2-logs-table-header') as HTMLElement | null
    expect(header).not.toBeNull()
    const headerLabels = [...header!.querySelectorAll('span')].map(s => s.textContent)
    expect(headerLabels).toContain('유형')

    // Each row exposes a kind cell with the resolved label + data-kind attribute.
    const kindCell = container.querySelector('.v2-logs-kind') as HTMLElement | null
    expect(kindCell).not.toBeNull()
    expect(kindCell!.getAttribute('data-kind')).toBe('tool')
    expect(kindCell!.textContent).toBe('TOOL')
  })
})

describe('logs vendored stylesheet', () => {
  it('vendors the phone stacked-card layout for the log stream (@640px)', () => {
    // Rows carry both `v2-logs-*` and the vendored `lg-*` classes, so the
    // `lg-*`-scoped media block reshapes the real stream, not a dead selector.
    const css = readFileSync(resolve(__dirname, '../styles/keeper-v2/logs.css'), 'utf8')
    expect(css).toContain('@media (max-width: 640px)')
    expect(css).toContain('grid-template-areas')
    expect(css).toContain('.lg-colhd { display: none; }')
  })

  it('pins the column header while the event stream scrolls', () => {
    // Sticky column header stays visible over a multi-thousand-row stream. This
    // only works while .v2-logs-panel does not clip: an overflow:hidden there
    // pins the sticky element to a non-scrolling ancestor and it scrolls away.
    const css = readFileSync(resolve(__dirname, '../styles/v2-logs.css'), 'utf8')
    const headerRule = css.match(/\.v2-logs-table-header\s*\{([^}]*)\}/)?.[1] ?? ''
    expect(headerRule).toContain('position: sticky')
    expect(headerRule).toContain('top: 0')
    const panelRule = css.match(/\.v2-logs-panel\s*\{([^}]*)\}/)?.[1] ?? ''
    // overflow: visible (not hidden) keeps the sticky header pinned to the page
    // scroller. Match the declaration, not the rationale comment above it.
    expect(panelRule).toMatch(/overflow:\s*visible\s*;/)
    expect(panelRule).not.toMatch(/overflow:\s*hidden\s*;/)
  })

  it('anchors the advanced menu to the viewport-side edge on narrow screens', () => {
    const css = readFileSync(resolve(__dirname, '../styles/v2-logs.css'), 'utf8')
    expect(css).toMatch(/\.v2-logs-advanced-menu \.v2-logs-advanced\s*\{[^}]*position:\s*fixed;[^}]*right:\s*12px;[^}]*left:\s*12px;[^}]*width:\s*auto;/)
  })
})
