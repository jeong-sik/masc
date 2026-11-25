import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { html } from 'htm/preact'
import { render, cleanup, fireEvent, waitFor } from '@testing-library/preact'
import { resourceCache } from '../../core/resource-cache'
import { resetAuthStateForTests, authSession } from '../../core/auth'
import { resetObserverStateForTests } from '../../core/observer'
import { resetTimeWindowForTests } from '../../core/time-window'
import { decodePulseKeepers } from './pulse-data'
import { buildAttentionQueue } from './pulse-model'
import { PulseWorkspace } from './index'
import { decodeKeeperRoster } from '../keepers/keepers-api'
import { KeeperHeader } from '../keepers/keeper-header'
import type { PulseKeeperRow } from './types'

describe('Pulse keeper error detail — typed decode and surfaces', () => {
  it('decodes runtime_blocker_class and lane attempt/dispatch/provider without prose matching', () => {
    const rows = decodePulseKeepers({
      keepers: [
        {
          name: 'e-masc-the-leader',
          status: 'running',
          phase: 'failing',
          health: 'failing',
          paused: false,
          keepalive_running: true,
          runtime_id: 'vibe_acp',
          runtime_blocker_summary: 'Provider runtime error from vibe_acp (rate_limited): quota exhausted',
          runtime_blocker_signature: 'rate_limited: quota exhausted',
          runtime_blocker_class: 'provider_runtime_error',
          runtime_lane_observation: {
            state: 'observed',
            evidence: {
              failures: [
                {
                  runtime_id: 'vibe_acp',
                  attempt: 1,
                  dispatch: 'dispatched',
                  failure: { cause: { kind: 'provider_rate_limited', provider: 'vibe_acp', detail: 'quota exhausted' } },
                  api_candidate_fault: { kind: 'binding', fact: 'rate_limit' },
                  summary: 'Runtime provider vibe_acp rate-limited the request: quota exhausted',
                },
              ],
              terminal: { kind: 'not_observed' },
            },
            turn: { trace_id: 't-1', turn_count: 42, ended_at: '2026-11-25T00:00:00Z' },
            error: null,
          },
          last_failure: { cause: 'provider', at_unix: 1_700_000_050 },
        },
        {
          name: 'code-reviewer-father',
          status: 'running',
          phase: 'idle',
          health: 'healthy',
          paused: false,
          keepalive_running: true,
          runtime_id: 'claude-code',
          runtime_blocker_summary: 'Current turn was cancelled by explicit operator request.',
          runtime_blocker_signature: null,
          runtime_blocker_class: 'operator_interrupt',
          runtime_lane_observation: {
            evidence: {
              failures: [
                {
                  runtime_id: 'claude-code',
                  attempt: 0,
                  dispatch: 'dispatched',
                  failure: { cause: { kind: 'operator_cancelled' } },
                  summary: 'operator interrupted the turn',
                },
              ],
              terminal: { kind: 'not_observed' },
            },
          },
          last_failure: { cause: 'turn', at_unix: 1_700_000_000 },
        },
      ],
    })

    expect(rows).toHaveLength(2)
    const failing = rows[0]!
    expect(failing.runtime_blocker_class).toBe('provider_runtime_error')
    expect(failing.runtime_blocker_summary).toBe('Provider runtime error from vibe_acp (rate_limited): quota exhausted')
    expect(failing.runtime_lane_failures).toHaveLength(1)
    const lane = failing.runtime_lane_failures![0]!
    expect(lane.runtime_id).toBe('vibe_acp')
    expect(lane.attempt).toBe(1)
    expect(lane.dispatch).toBe('dispatched')
    expect(lane.failure_kind).toBe('provider_rate_limited')
    expect(lane.provider).toBe('vibe_acp')
    expect(lane.fault_kind).toBe('rate_limit')

    const cancelled = rows[1]!
    expect(cancelled.runtime_blocker_class).toBe('operator_interrupt')
    expect(cancelled.runtime_blocker_summary).toBe('Current turn was cancelled by explicit operator request.')

    // buildAttentionQueue must surface both via typed presence (no prose heuristic)
    const now = 1_700_000_100
    const queue = buildAttentionQueue({ approvals: [], asks: [], keepers: rows, nowSec: now })
    const names = queue.map((q) => q.keeper)
    expect(names).toContain('e-masc-the-leader')
    expect(names).toContain('code-reviewer-father')
    const failingItem = queue.find((q) => q.keeper === 'e-masc-the-leader')!
    expect(failingItem.kind).toBe('keeper_failure')
    expect((failingItem.raw as PulseKeeperRow).runtime_blocker_summary).toBe('Provider runtime error from vibe_acp (rate_limited): quota exhausted')
    expect((failingItem.raw as PulseKeeperRow).runtime_blocker_class).toBe('provider_runtime_error')
  })

  it('decodes keeper roster lane typed fields and keepers header shows byte-verified detail', () => {
    const items = decodeKeeperRoster({
      keepers: [
        {
          name: 'pr-updater',
          status: 'running',
          phase: 'failing',
          health: 'failing',
          paused: false,
          keepalive_running: true,
          activation_mode: 'autonomous',
          runtime_id: 'gemini.gemini-api',
          runtime_blocker_summary: 'Provider runtime error from gemini.gemini-api (auth): invalid key',
          runtime_blocker_signature: null,
          runtime_blocker_class: 'provider_runtime_error',
          runtime_lane_observation: {
            evidence: {
              failures: [
                {
                  runtime_id: 'gemini.gemini-api',
                  attempt: 0,
                  dispatch: 'rejected_before_dispatch',
                  failure: { cause: { kind: 'provider_auth_required', provider: 'gemini.gemini-api', detail: 'invalid key' } },
                  summary: 'Runtime provider gemini.gemini-api authentication required: invalid key',
                },
              ],
              terminal: { kind: 'not_observed' },
            },
          },
          last_failure: { cause: 'provider', at_unix: 1_700_000_200 },
          next_action: 'inspect_provider_runtime_cause',
        },
      ],
    })
    expect(items[0]!.runtime_blocker_class).toBe('provider_runtime_error')
    expect(items[0]!.runtime_lane_failures![0]!.provider).toBe('gemini.gemini-api')
    expect(items[0]!.runtime_lane_failures![0]!.attempt).toBe(0)

    const hdr = render(
      html`<${KeeperHeader}
        keeper=${items[0]!}
        activeTab="chat"
        onSelectTab=${vi.fn()}
        onLifecycleMutated=${vi.fn()}
        onDeleted=${vi.fn()}
      />`,
    )
    // byte-verified: summary, class, provider, attempt/dispatch must be visible (typed fields, not TUI chrome)
    expect(hdr.container.textContent).toContain('Provider runtime error from gemini.gemini-api (auth): invalid key')
    expect(hdr.container.textContent).toContain('provider_runtime_error')
    expect(hdr.container.textContent).toContain('gemini.gemini-api')
    expect(hdr.container.textContent).toContain('attempt 0')
    hdr.unmount()
  })

  it('pulse preview render shows byte-verified keeper error without JSON dump and move route stays canonical', async () => {
    beforeEach(() => {
      resetAuthStateForTests()
      resetTimeWindowForTests('24h')
      resetObserverStateForTests()
      resourceCache.clearAll()
      authSession.value = {
        kind: 'single_user_local',
        mode: 'single_user',
        tokenPresent: true,
        authMethods: { google: false, github: false, dev_token: false },
        workspaceId: 'default',
      }
    })
    afterEach(() => {
      cleanup()
      vi.restoreAllMocks()
    })

    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input)
        const json = (data: unknown) =>
          new Response(JSON.stringify(data), { status: 200, headers: { 'Content-Type': 'application/json' } })
        if (url.includes('/api/v1/dashboard/shell')) {
          return json({ counts: { keepers: 1, configured_keepers: 1 }, groups: [] })
        }
        if (url.includes('/api/v1/gate/keepers')) {
          return json({
            keepers: [
              {
                name: 'e-masc-the-leader',
                status: 'running',
                phase: 'failing',
                health: 'failing',
                paused: false,
                keepalive_running: true,
                runtime_id: 'vibe_acp',
                runtime_blocker_summary: 'Provider runtime error from vibe_acp (rate_limited): quota exhausted',
                runtime_blocker_signature: 'rate_limited: quota exhausted',
                runtime_blocker_class: 'provider_runtime_error',
                runtime_lane_observation: {
                  evidence: {
                    failures: [
                      {
                        runtime_id: 'vibe_acp',
                        attempt: 2,
                        dispatch: 'dispatched',
                        failure: { cause: { kind: 'provider_rate_limited', provider: 'vibe_acp', detail: 'quota exhausted' } },
                        summary: 'Runtime provider vibe_acp rate-limited the request: quota exhausted',
                      },
                    ],
                    terminal: { kind: 'not_observed' },
                  },
                },
                last_failure: { cause: 'provider', at_unix: 1_700_000_050 },
              },
            ],
          })
        }
        return json({ keepers: [], pending: [], asks: [], tree: [], posts: [], data: {}, points: [] })
      }),
    )

    const onNavigate = vi.fn()
    const onInspect = vi.fn()
    const { container, getAllByRole } = render(
      html`<${PulseWorkspace} subroute="" onNavigate=${onNavigate} onInspect=${onInspect} />`,
    )
    await waitFor(() => {
      expect(getAllByRole('button', { name: '미리보기' }).length).toBeGreaterThan(0)
      expect(container.textContent).toContain('Provider runtime error from vibe_acp')
    })

    // Click 미리보기 on keeper_failure — payload must carry structured render
    const previewBtns = getAllByRole('button', { name: '미리보기' })
    fireEvent.click(previewBtns[0]!)
    expect(onInspect).toHaveBeenCalled()
    const payload = onInspect.mock.calls[0]![0] as {
      kind: string
      title: string
      render?: () => unknown
      data: unknown
    }
    expect(payload.kind).toBe('keeper_failure')
    expect(typeof payload.render).toBe('function')
    // Rendered drawer content must contain byte-verified fields (summary, provider, attempt)
    const rendered = render(html`<div>${payload.render!()}</div>`)
    expect(rendered.container.textContent).toContain('Provider runtime error from vibe_acp (rate_limited): quota exhausted')
    expect(rendered.container.textContent).toContain('rate_limited: quota exhausted')
    expect(rendered.container.textContent).toContain('vibe_acp')
    expect(rendered.container.textContent).toContain('attempt 2')
    rendered.unmount()

    // 이동 routes to canonical keeper detail (chat tab) where header banner shows same typed detail
    const moveBtns = getAllByRole('button', { name: '이동' })
    fireEvent.click(moveBtns[0]!)
    expect(onNavigate).toHaveBeenCalledWith('/keepers/e-masc-the-leader/chat')
  })
})
