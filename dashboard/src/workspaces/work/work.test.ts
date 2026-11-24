import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('uplot', () => {
  class MockUPlot {
    width = 480
    constructor(_opts: unknown, _data: unknown, mount?: HTMLElement) {
      if (mount) {
        const el = document.createElement('div')
        el.className = 'uplot-mock'
        mount.appendChild(el)
      }
    }
    setData(): void {}
    setSize(): void {}
    destroy(): void {}
    static sync(key: string) {
      return { key }
    }
  }
  return { default: MockUPlot }
})
import { bumpSessionEpoch, resetAuthStateForTests } from '../../core/auth'
import { resetObserverStateForTests } from '../../core/observer'
import { resourceCache } from '../../core/resource-cache'
import {
  WorkWorkspace,
  buildCandleTrendSeries,
  checkTaskGoalLinkable,
  computeTaskFilterCounts,
  decodeCandleLedger,
  decodeGoalPhaseStrict,
  formatMilliCandles,
  parseCandleMilli,
  validateNewGoalInput,
  type TaskItem,
} from './index'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

async function flushUi(rounds = 6): Promise<void> {
  for (let i = 0; i < rounds; i++) {
    await new Promise((r) => setTimeout(r, 0))
  }
}

describe('workspaces/work', () => {
  let container: HTMLDivElement
  const origFetch = globalThis.fetch

  beforeEach(() => {
    resetAuthStateForTests()
    resetObserverStateForTests()
    resourceCache.clearAll()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    globalThis.fetch = origFetch
    vi.restoreAllMocks()
    resourceCache.clearAll()
    resetAuthStateForTests()
    resetObserverStateForTests()
  })

  it('strict Goal phase decoder rejects legacy status field and requires resume_phase for Paused/Blocked', () => {
    // Rejects legacy status field
    const legacy = decodeGoalPhaseStrict({ phase: 'Executing', status: 'active' })
    expect(legacy.ok).toBe(false)

    // Accepts all 7 closed phases properly
    expect(decodeGoalPhaseStrict({ phase: 'Executing' })).toEqual({ ok: true, value: { phase: 'Executing', resumePhase: null } })
    expect(decodeGoalPhaseStrict({ phase: 'Verifying' })).toEqual({ ok: true, value: { phase: 'Verifying', resumePhase: null } })
    expect(decodeGoalPhaseStrict({ phase: 'Awaiting_confirmation' })).toEqual({ ok: true, value: { phase: 'Awaiting_confirmation', resumePhase: null } })
    expect(decodeGoalPhaseStrict({ phase: 'Completed' })).toEqual({ ok: true, value: { phase: 'Completed', resumePhase: null } })
    expect(decodeGoalPhaseStrict({ phase: 'Dropped' })).toEqual({ ok: true, value: { phase: 'Dropped', resumePhase: null } })
    expect(decodeGoalPhaseStrict({ phase: 'Paused', resume_phase: 'Executing' })).toEqual({
      ok: true,
      value: { phase: 'Paused', resumePhase: 'Executing' },
    })
    expect(decodeGoalPhaseStrict({ phase: 'Blocked', resume_phase: 'Verifying' })).toEqual({
      ok: true,
      value: { phase: 'Blocked', resumePhase: 'Verifying' },
    })

    // Rejects Paused/Blocked without resume_phase
    expect(decodeGoalPhaseStrict({ phase: 'Paused' }).ok).toBe(false)
    expect(decodeGoalPhaseStrict({ phase: 'Blocked' }).ok).toBe(false)
  })

  it('Goal creation validation enforces measure and non-empty procedure per constitution.xml', () => {
    const missingProc = validateNewGoalInput({
      title: 'Ship renewal',
      measureKind: 'done_when',
      condition: 'All tests pass',
      noun: '',
      total: '1',
      unit: '',
      direction: 'at_least',
      target: '1',
      procedure: '   ',
      priority: 1,
    })
    expect(missingProc.ok).toBe(false)

    const valid = validateNewGoalInput({
      title: 'Keep DOM under 1200',
      measureKind: 'quantity',
      condition: '',
      noun: '',
      total: '1',
      unit: 'nodes',
      direction: 'at_most',
      target: '1200',
      procedure: 'Run playwright DOM node audit across all routes',
      priority: 1,
    })
    expect(valid.ok).toBe(true)
    if (valid.ok) {
      expect(valid.value.measure).toEqual({
        kind: 'quantity',
        unit: 'nodes',
        direction: 'at_most',
        target: 1200,
      })
    }
  })

  it('Tasks filter counts reconcile Active = Claimed + InProgress and enforce goalless set_task_goal rule', () => {
    const tasks: TaskItem[] = [
      { id: 't1', title: 'Claimed task', description: null, priority: 1, status: 'Claimed', assignee: 'k1', goalId: null, verificationId: null, createdAt: null, updatedAt: null, cancelledBy: null, cancelReason: null },
      { id: 't2', title: 'InProgress task', description: null, priority: 1, status: 'InProgress', assignee: 'k2', goalId: 'g1', verificationId: null, createdAt: null, updatedAt: null, cancelledBy: null, cancelReason: null },
      { id: 't3', title: 'Awaiting task', description: null, priority: 2, status: 'AwaitingVerification', assignee: 'k1', goalId: 'g1', verificationId: 'v1', createdAt: null, updatedAt: null, cancelledBy: null, cancelReason: null },
      { id: 't4', title: 'Todo unlinked', description: null, priority: 2, status: 'Todo', assignee: null, goalId: null, verificationId: null, createdAt: null, updatedAt: null, cancelledBy: null, cancelReason: null },
      { id: 't5', title: 'Done task', description: null, priority: 3, status: 'Done', assignee: 'k1', goalId: null, verificationId: null, createdAt: null, updatedAt: null, cancelledBy: null, cancelReason: null },
    ]

    const counts = computeTaskFilterCounts(tasks)
    expect(counts.all).toBe(5)
    expect(counts.active).toBe(2) // Claimed (1) + InProgress (1) — never 0!
    expect(counts.awaiting_verify).toBe(1)
    expect(counts.todo).toBe(1)
    expect(counts.unlinked).toBe(2) // t1 + t4 (non-terminal goalless tasks)
    expect(counts.done).toBe(1)

    // set_task_goal only for goalless non-terminal tasks
    expect(checkTaskGoalLinkable(tasks[0]!).ok).toBe(true)
    expect(checkTaskGoalLinkable(tasks[1]!)).toEqual({ ok: false, error: 'Already_assigned' })
    expect(checkTaskGoalLinkable(tasks[4]!)).toEqual({ ok: false, error: 'Task_finished' })
  })

  it('Goals tab wraps completion confirmation in TargetLockedAction and jumps to /work/tasks on linked task click', async () => {
    const onNavigate = vi.fn()
    const onInspect = vi.fn()

    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.startsWith('/api/v1/dashboard/goals')) {
        return jsonResponse({
          tree: [
            {
              id: 'goal-1',
              title: 'Finish Layer 6 Work & Knowledge',
              phase: 'Awaiting_confirmation',
              priority: 1,
              measure: { kind: 'done_when', condition: 'All Work & Knowledge tests pass' },
              procedure: 'Run pnpm --dir dashboard test',
              criterion_revision: 'crev-7',
              criterion_review: { state: 'viable', reason: 'Testable and concrete' },
              linked_task_count: 1,
              tasks: [
                { id: 'task-42', title: 'Build Goals tab', status: 'in_progress', assignee: 'ws-work', priority: 1 },
              ],
            },
          ],
        })
      }
      if (url.startsWith('/api/v1/verification/requests')) {
        return jsonResponse({ requests: [] })
      }
      if (url.startsWith('/health?full=1')) {
        return jsonResponse({
          paths: { effective_base_path: '/ws/masc', effective_masc_root: '/ws/masc/.masc' },
        })
      }
      if (url.startsWith('/api/v1/goals/confirmation')) {
        return jsonResponse({
          inspection_operator_id: 'op-1',
          runtime_instance_id: 'inst-1',
          goal: { id: 'goal-1', phase: 'Awaiting_confirmation' },
          verification: {
            completion: {
              request_id: 'conf-req-1',
              run_id: 'vrun-9',
              actor: 'verifier-agent',
              evidence: '563/563 tests green',
              recorded_at: '2026-11-24T06:00:00Z',
              criterion: { revision: 'crev-7' },
            },
          },
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${WorkWorkspace} subroute="goals" onNavigate=${onNavigate} onInspect=${onInspect} />`,
      container,
    )
    await flushUi()

    expect(container.textContent).toContain('Finish Layer 6 Work & Knowledge')
    const tla = container.querySelector('.tla')
    expect(tla).not.toBeNull()
    expect(tla!.getAttribute('data-locked')).toBe('false')
    expect(tla!.textContent).toContain('conf-req-1')
    expect(tla!.textContent).toContain('crev-7')

    // Session epoch change immediately locks Goal Confirmation action
    bumpSessionEpoch()
    await flushUi(2)
    expect(container.querySelector('.tla')!.getAttribute('data-locked')).toBe('true')
    expect((container.querySelector('.tla fieldset') as HTMLFieldSetElement).disabled).toBe(true)

    // Clicking linked task jumps to /work/tasks/task-42
    const taskButtons = [...container.querySelectorAll('button')].filter((b) =>
      b.textContent?.includes('Build Goals tab'),
    )
    expect(taskButtons.length).toBeGreaterThan(0)
    taskButtons[0]!.click()
    expect(onNavigate).toHaveBeenCalledWith('/work/tasks/task-42')
  })

  it('Tasks tab fetches cursor-paginated history with task_id + positive limit and handles 409 source changed', async () => {
    const requestedUrls: string[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      requestedUrls.push(url)
      if (url.startsWith('/api/v1/dashboard/planning')) {
        return jsonResponse({
          goals: [],
          tasks: [
            { id: 'task-99', title: 'Audit history cursor', status: 'in_progress', assignee: 'sangsu', priority: 1, goal_id: null },
          ],
        })
      }
      if (url.startsWith('/api/v1/dashboard/execution')) {
        return jsonResponse({ tasks: [] })
      }
      if (url.startsWith('/api/v1/dashboard/scheduled-automation')) {
        return jsonResponse({ status: 'ok', schedule_store_known: true, schedule_store_read_error: null, request_count: 0, requests: [], truncated: false })
      }
      if (url.startsWith('/api/v1/dashboard/tasks/history/page')) {
        if (url.includes('cursor=cur-2')) {
          return jsonResponse({ error: { code: 'task_history_source_changed', message: 'source rotated' } }, 409)
        }
        return jsonResponse({
          schema: 'masc.task-history.page/v2',
          task_id: 'task-99',
          cursor: null,
          sources: [{ source: 'backlog', state: 'observed' }],
          events: [{ source: 'backlog', file: 'tasks.jsonl', offset: 128, event: { kind: 'claimed' } }],
          next_cursor: 'cur-2',
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${WorkWorkspace} subroute="tasks" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi()

    const historyCalls = requestedUrls.filter((u) => u.startsWith('/api/v1/dashboard/tasks/history/page'))
    expect(historyCalls.length).toBeGreaterThan(0)
    expect(historyCalls[0]).toContain('task_id=task-99')
    expect(historyCalls[0]).toContain('limit=20')
    expect(container.textContent).toContain('claimed')

    // Click load more -> triggers 409 task_history_source_changed banner
    const loadMoreBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('이전 이력 더 불러오기'),
    )
    expect(loadMoreBtn).toBeDefined()
    loadMoreBtn!.click()
    await flushUi()
    expect(container.textContent).toContain('409 task_history_source_changed')
  })

  it('Unified Inbox wraps Tool Approval in TargetLockedAction, auto-locks on epoch change, and dispatches approve', async () => {
    const postCalls: { url: string; body: unknown }[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (init?.method === 'POST') {
        postCalls.push({ url, body: init.body ? JSON.parse(String(init.body)) : null })
        return jsonResponse({ settled: true })
      }
      if (url.startsWith('/api/v1/keepers/tool-approvals')) {
        return jsonResponse({
          pending: [
            {
              approval_id: 'appr-77',
              tool_call_id: 'tc-77',
              keeper: 'code-reviewer-sister',
              tool: 'masc_shell_exec',
              args: { cmd: 'git status' },
              question: 'Allow shell command?',
              because: 'Write-capable shell tool',
              asked_at: 1732430000,
              timeout_sec: 120,
              revision: 'rev-11',
            },
          ],
        })
      }
      if (url.startsWith('/api/v1/keepers/asks')) {
        return jsonResponse({ scope: 'fleet', open_count: 0, asks: [] })
      }
      if (url.startsWith('/api/v1/dashboard/gate')) {
        return jsonResponse({
          approval_queue: [],
          recent_resolved: [
            {
              id: 'res-1',
              keeper_name: 'sangsu',
              tool_name: 'masc_git_push',
              decision_kind: 'approve',
              decision_source: 'human_operator',
              decision_reason: null,
              actor: 'op-1',
              resolved_at: '2026-11-24T05:00:00Z',
            },
          ],
        })
      }
      if (url.startsWith('/api/v1/dashboard/planning')) {
        return jsonResponse({ goals: [] })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${WorkWorkspace} subroute="inbox" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi()

    const tla = container.querySelector('.tla')
    expect(tla).not.toBeNull()
    expect(tla!.getAttribute('data-locked')).toBe('false')
    expect(tla!.textContent).toContain('default')
    expect(tla!.textContent).toContain('code-reviewer-sister')
    expect(tla!.textContent).toContain('appr-77')
    expect(tla!.textContent).toContain('rev-11')

    // Approve dispatches exact body
    const approveBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('승인 (Approve)'),
    )
    expect(approveBtn).toBeDefined()
    approveBtn!.click()
    await flushUi()
    expect(postCalls[0]).toEqual({
      url: '/api/v1/keepers/tool-approval',
      body: {
        name: 'code-reviewer-sister',
        tool_call_id: 'tc-77',
        approval_id: 'appr-77',
        decision: 'approve',
      },
    })

    // Epoch bump auto-locks TargetLockedAction
    bumpSessionEpoch()
    await flushUi(2)
    expect(container.querySelector('.tla')!.getAttribute('data-locked')).toBe('true')
  })

  it('Candle parses decimal-string *_milli vs numeric balance_milli, distinguishes absent vs 0, and fires Hold Release', async () => {
    expect(parseCandleMilli('1234500')).toBe(1234500)
    expect(parseCandleMilli('0')).toBe(0)
    expect(parseCandleMilli(5000)).toBe(5000)
    expect(parseCandleMilli(null)).toBeNull()
    expect(parseCandleMilli('')).toBeNull()

    expect(formatMilliCandles('1234500')).toBe('1,234.500')
    expect(formatMilliCandles('0')).toBe('0.000')
    expect(formatMilliCandles(null)).toBe('없음')

    const samplePayload = {
      ledger_state: 'present',
      total_events: 2,
      balance_error: null,
      policy: {
        configuration: 'enabled',
        disabled_reason: null,
        pricing_mode: 'supply_scaled',
        half_life: { mode: 'decay', half_life_hours: 168, half_life_sec: 604800 },
        half_life_sec: 604800,
      },
      supply: {
        issued_milli: '50000',
        burned_milli: '0',
        circulating_milli: '42500.5',
        total_supply_milli: '50000',
        active_keepers: 1,
      },
      balances: [
        {
          keeper: 'sangsu',
          balance_milli: 50000,
          decayed_milli: '42500.5',
          last_event_unix: 1732430000,
          owned_items: ['crown'],
          equipped: { face: null, neck: null, head: 'crown', hand: null, base: null },
        },
      ],
      diagnostics: {
        unattributed_count: 0,
        backlog_fenced_count: 0,
        zero_linked_tasks_goals: 0,
        held_windows_count: 1,
        items: [
          {
            goal_id: 'goal-held-1',
            title: 'Held Payout Goal',
            kind: 'candidate_window_held',
            observation: 'Waiting for candidate fence',
            linked_task_count: 2,
            at_unix: 1732430000,
            diagnostic_hint: 'Release hold after verifying linked tasks',
          },
        ],
      },
      recent_events: [
        { seq: 1, at_unix: 1732400000, at_rfc3339: '2026-11-24T00:00:00Z', kind: 'paid', total_milli: '30000' },
        { seq: 2, at_unix: 1732430000, at_rfc3339: '2026-11-24T08:00:00Z', kind: 'paid', total_milli: '20000' },
      ],
    }

    const decoded = decodeCandleLedger(samplePayload)
    expect(decoded.ok).toBe(true)
    if (decoded.ok) {
      expect(decoded.value.supply.circulatingMilli).toBe(42500.5)
      expect(decoded.value.balances[0]!.balanceMilli).toBe(50000)
      expect(decoded.value.balances[0]!.decayedMilli).toBe(42500.5)
      const trend = buildCandleTrendSeries(decoded.value)
      expect(trend.timestamps).toEqual([1732400000, 1732430000])
      expect(trend.cumulativeIssued).toEqual([30, 50])
      expect(trend.decayedSupply[1]!).toBeLessThan(50)
    }

    const releaseCalls: { url: string; body: unknown }[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.startsWith('/api/v1/candle/ledger')) {
        return jsonResponse({ schema_version: 1, instance_id: 'i1', generated_at_unix: 1, data: samplePayload })
      }
      if (url === '/api/v1/dashboard/goals/candle/hold/release' && init?.method === 'POST') {
        releaseCalls.push({ url, body: JSON.parse(String(init.body)) })
        return jsonResponse({ ok: true, outcome: 'released', goal_id: 'goal-held-1' })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${WorkWorkspace} subroute="candle" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi()

    expect(container.textContent).toContain('42.501')
    expect(container.textContent).toContain('0.000') // burned_milli = "0" renders "0.000", not "없음"
    expect(container.textContent).toContain('sangsu')
    expect(container.querySelector('img.kb-portrait')).not.toBeNull()

    const releaseBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.trim() === 'Hold Release',
    )
    expect(releaseBtn).toBeDefined()
    releaseBtn!.click()
    await flushUi()
    expect(releaseCalls).toEqual([
      { url: '/api/v1/dashboard/goals/candle/hold/release', body: { goal_id: 'goal-held-1' } },
    ])
  })
})
