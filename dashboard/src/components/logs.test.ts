import { h } from 'preact'
import { cleanup, render, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { LogEntry } from '../api/dashboard'
import { logDiagnosticCause, summarizeLogWindow } from './logs'

function entry(overrides: Partial<LogEntry>): LogEntry {
  return {
    seq: 1,
    ts: '2026-05-14T00:00:00Z',
    level: 'INFO',
    raw_level: 'INFO',
    normalized_level: 'INFO',
    source: 'structured',
    legacy_classified: false,
    module: 'Keeper',
    message: 'ok',
    details: null,
    ...overrides,
  }
}

async function loadLogs(fetchLogs: ReturnType<typeof vi.fn>) {
  vi.resetModules()
  vi.doMock('../api/dashboard.js', () => ({
    fetchLogs,
  }))
  return import('./logs')
}

describe('log diagnostics', () => {
  it('classifies timeout and cascade messages without structured envelopes', () => {
    expect(
      logDiagnosticCause(
        entry({
          level: 'WARN',
          normalized_level: 'WARN',
          message:
            'keeper_llm_bridge: OAS execution timed out after 300.0s (budget=300s)',
        }),
      ),
    ).toBe('oas_timeout_budget')

    expect(
      logDiagnosticCause(
        entry({
          level: 'ERROR',
          normalized_level: 'ERROR',
          message:
            'all cascades exhausted: Cascade attempt liveness guard killed runtime lane coding_plan: inter_chunk_idle',
        }),
      ),
    ).toBe('inter_chunk_idle')
  })

  it('classifies keeper telemetry and registry noise causes', () => {
    expect(
      logDiagnosticCause(
        entry({
          level: 'INFO',
          normalized_level: 'INFO',
          message:
            'keeper:analyst after_turn usage telemetry unavailable runtime_lane=runtime reasons=zero_token_usage_reported input=0 output=0 context_max=200000',
        }),
      ),
    ).toBe('usage_zero_tokens')

    expect(
      logDiagnosticCause(
        entry({
          level: 'WARN',
          normalized_level: 'WARN',
          message:
            'registry: orphan threshold breached name=analyst base_path=/Users/dancer/me drops=5 window=60s',
        }),
      ),
    ).toBe('registry_orphan_threshold')
  })

  it('prefers failure envelope cause codes and summarizes the current window', () => {
    const entries = [
      entry({
        seq: 3,
        level: 'ERROR',
        normalized_level: 'ERROR',
        module: 'Keeper',
        message: 'keeper_llm_bridge timeout',
        details: {
          failure_envelope: {
            surface: 'keeper_oas_bridge',
            entity_kind: 'oas_execution',
            entity_id: null,
            cause_code: 'oas_timeout_budget',
            severity: 'bad',
            summary: 'OAS execution exceeded budget',
            recoverability: 'operator_action_required',
            operator_action: 'inspect_timeout_budget',
            evidence_ref: { timeout_sec: 300 },
          },
        },
      }),
      entry({
        seq: 2,
        level: 'WARN',
        normalized_level: 'WARN',
        module: 'Task',
        message: 'Ignoring legacy verification directory /tmp/verifications',
      }),
      entry({
        seq: 1,
        level: 'INFO',
        normalized_level: 'INFO',
        module: 'Keeper',
        message: 'normal',
      }),
    ]

    const summary = summarizeLogWindow(entries)
    expect(summary.errors).toBe(1)
    expect(summary.warnings).toBe(1)
    expect(summary.failureEnvelopes).toBe(1)
    expect(summary.topCauses).toContainEqual({ cause: 'oas_timeout_budget', count: 1 })
    expect(summary.topCauses).toContainEqual({
      cause: 'legacy_verification_dir',
      count: 1,
    })
    expect(summary.topModules[0]).toEqual({ module: 'Keeper', count: 2 })
  })
})

describe('LogViewer Code links', () => {
  afterEach(() => {
    cleanup()
    vi.clearAllMocks()
    vi.resetModules()
    vi.doUnmock('../api/dashboard.js')
    window.location.hash = ''
  })

  it('links safe structured log file details back to the Code IDE route', async () => {
    const fetchLogs = vi.fn().mockResolvedValue({
      total: 1,
      entries: [{
        seq: 1,
        ts: '2026-05-14T00:00:00Z',
        level: 'INFO',
        raw_level: 'INFO',
        normalized_level: 'INFO',
        source: 'structured',
        legacy_classified: false,
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

    codeLink.click()
    expect(window.location.hash).toBe(
      '#code?section=ide-shell&view=source&file=lib%2Fruntime.ml&line=12&surface=Log&label=keeper_tool&source_id=log%3A1',
    )
  })

  it('does not render Code links for unsafe absolute log file paths', async () => {
    const fetchLogs = vi.fn().mockResolvedValue({
      total: 1,
      entries: [{
        seq: 2,
        ts: '2026-05-14T00:00:00Z',
        level: 'INFO',
        raw_level: 'INFO',
        normalized_level: 'INFO',
        source: 'structured',
        legacy_classified: false,
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
        raw_level: 'WARN',
        normalized_level: 'WARN',
        source: 'structured',
        legacy_classified: false,
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
})
