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
import { authSession, bumpSessionEpoch, resetAuthStateForTests } from '../../core/auth'
import { resetObserverStateForTests } from '../../core/observer'
import { resourceCache } from '../../core/resource-cache'
import { resetPortraitCacheForTests } from '../../lib/portrait-cache'
import {
  WorkWorkspace,
  buildCandleTrendSeries,
  checkTaskGoalLinkable,
  computeTaskFilterCounts,
  decodeCandleLedger,
  decodeGoalConfirmation,
  decodeGoalPhaseStrict,
  formatMilliCandles,
  parseCandleMilli,
  validateNewGoalInput,
  type TaskItem,
  type WorkspacePreconditionSnapshot,
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

function setMultiAccountSessionForTest(): void {
  authSession.value = {
    kind: 'multi_account_signed_in',
    mode: 'multi_account',
    accountId: 'acc-1',
    email: 'operator@example.com',
    displayName: 'Operator',
    role: 'admin',
    csrfToken: 'csrf-tok-1',
    authMethods: { google: true, github: false, dev_token: false },
    workspaceId: 'default',
  }
}

describe('workspaces/work', () => {
  let container: HTMLDivElement
  const origFetch = globalThis.fetch

  beforeEach(() => {
    resetAuthStateForTests()
    resetObserverStateForTests()
    resetPortraitCacheForTests()
    resourceCache.clearAll()
    vi.spyOn(HTMLElement.prototype, 'clientHeight', 'get').mockReturnValue(480)
    vi.spyOn(HTMLElement.prototype, 'clientWidth', 'get').mockReturnValue(600)
    vi.spyOn(HTMLElement.prototype, 'offsetHeight', 'get').mockReturnValue(480)
    vi.spyOn(HTMLElement.prototype, 'offsetWidth', 'get').mockReturnValue(600)
    vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockReturnValue({
      width: 600,
      height: 480,
      top: 0,
      left: 0,
      bottom: 480,
      right: 600,
      x: 0,
      y: 0,
      toJSON() {
        return {}
      },
    } as DOMRect)
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    globalThis.fetch = origFetch
    vi.restoreAllMocks()
    resourceCache.clearAll()
    resetPortraitCacheForTests()
    resetAuthStateForTests()
    resetObserverStateForTests()
  })

  it('strict Goal phase decoder rejects legacy status field and requires resume_phase for Paused/Blocked', () => {
    const legacy = decodeGoalPhaseStrict({ phase: 'Executing', status: 'active' })
    expect(legacy.ok).toBe(false)

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

    expect(decodeGoalPhaseStrict({ phase: 'Paused' }).ok).toBe(false)
    expect(decodeGoalPhaseStrict({ phase: 'Blocked' }).ok).toBe(false)
  })

  it('decodeGoalConfirmation parses nested verification.completion.verdict + /health runtime_instance_id and fails closed on non-proven or missing fields', () => {
    const wsOk: WorkspacePreconditionSnapshot = {
      base_path: '/ws/masc',
      masc_root: '/ws/masc/.masc',
      runtime_instance_id: 'inst-live-42',
    }
    const validRaw = {
      inspection_operator_id: 'op-1',
      goal: { id: 'goal-1', phase: 'Awaiting_confirmation' },
      verification: {
        goal_id: 'goal-1',
        completion: {
          state: 'proof_proven',
          verdict: {
            outcome: 'proven',
            reason: null,
            request_id: 'vr-100',
            verification_run_id: 'vrun-9',
            criterion: { revision: 'crev-7' },
            authority: { kind: 'system_llm_agent', actor: 'verifier-agent' },
            evidence: '574/574 tests green',
            recorded_at: '2026-11-24T06:00:00Z',
          },
        },
      },
    }

    const decoded = decodeGoalConfirmation(validRaw, 'goal-1', wsOk)
    expect(decoded.ok).toBe(true)
    if (decoded.ok) {
      expect(decoded.value.runtimeInstanceId).toBe('inst-live-42')
      expect(decoded.value.inspectionOperatorId).toBe('op-1')
      expect(decoded.value.requestId).toBe('vr-100')
      expect(decoded.value.verificationRunId).toBe('vrun-9')
      expect(decoded.value.criterionRevision).toBe('crev-7')
      expect(decoded.value.authorityKind).toBe('system_llm_agent')
      expect(decoded.value.actor).toBe('verifier-agent')
    }

    // Fails closed if runtime_instance_id missing from /health?full=1
    expect(decodeGoalConfirmation(validRaw, 'goal-1', { ...wsOk, runtime_instance_id: null }).ok).toBe(false)

    // Fails closed on stale_criterion or proof_refuted
    const staleRaw = {
      ...validRaw,
      verification: { goal_id: 'goal-1', completion: { state: 'stale_criterion', verdict: validRaw.verification.completion.verdict } },
    }
    expect(decodeGoalConfirmation(staleRaw, 'goal-1', wsOk).ok).toBe(false)

    const refutedRaw = {
      ...validRaw,
      verification: {
        goal_id: 'goal-1',
        completion: {
          state: 'proof_refuted',
          verdict: { ...validRaw.verification.completion.verdict, outcome: 'refuted', reason: 'failed assertion' },
        },
      },
    }
    expect(decodeGoalConfirmation(refutedRaw, 'goal-1', wsOk).ok).toBe(false)

    // Fails closed when verification_run_id or request_id is absent (never fabricates req-/run-)
    const missingRunId = {
      ...validRaw,
      verification: {
        goal_id: 'goal-1',
        completion: {
          state: 'proof_proven',
          verdict: { ...validRaw.verification.completion.verdict, verification_run_id: '' },
        },
      },
    }
    expect(decodeGoalConfirmation(missingRunId, 'goal-1', wsOk).ok).toBe(false)
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
    expect(counts.active).toBe(2)
    expect(counts.awaiting_verify).toBe(1)
    expect(counts.todo).toBe(1)
    expect(counts.unlinked).toBe(2)
    expect(counts.done).toBe(1)

    expect(checkTaskGoalLinkable(tasks[0]!).ok).toBe(true)
    expect(checkTaskGoalLinkable(tasks[1]!)).toEqual({ ok: false, error: 'Already_assigned' })
    expect(checkTaskGoalLinkable(tasks[4]!)).toEqual({ ok: false, error: 'Task_finished' })
  })

  it('Goals tab decodes nested proof_proven verdict + /health runtime_instance_id, scopes verifications strictly to linkedTasks, and dispatches confirmation via TargetLockedAction', async () => {
    const onNavigate = vi.fn()
    const onInspect = vi.fn()
    const postCalls: { url: string; body: unknown }[] = []

    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url === '/api/v1/goals/confirmation' && init?.method === 'POST') {
        postCalls.push({ url, body: JSON.parse(String(init.body)) })
        return jsonResponse({ ok: true })
      }
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
        // Contains ONLY an unrelated task verification — must NOT leak into goal-1!
        return jsonResponse({
          requests: [
            {
              request_id: 'vr-unrelated-999',
              task_id: 'other-task-999',
              task_title: 'Unrelated Goal Task',
              status: 'pending',
              worker: 'other-keeper',
              verifier: null,
              completion_contract: [],
              created_at: '2026-11-24T05:00:00Z',
              verdict: null,
            },
          ],
        })
      }
      if (url.startsWith('/health?full=1')) {
        return jsonResponse({
          build: { runtime_instance_id: 'inst-real-777' },
          paths: { effective_base_path: '/ws/masc', effective_masc_root: '/ws/masc/.masc' },
        })
      }
      if (url.startsWith('/api/v1/goals/confirmation')) {
        return jsonResponse({
          inspection_operator_id: 'op-1',
          goal: { id: 'goal-1', phase: 'Awaiting_confirmation' },
          verification: {
            goal_id: 'goal-1',
            completion: {
              state: 'proof_proven',
              verdict: {
                outcome: 'proven',
                reason: null,
                request_id: 'conf-req-1',
                verification_run_id: 'vrun-9',
                criterion: { revision: 'crev-7' },
                authority: { kind: 'system_llm_agent', actor: 'verifier-agent' },
                evidence: '574/574 tests green',
                recorded_at: '2026-11-24T06:00:00Z',
              },
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
    expect(container.querySelector('.wk-subbar')).toBeNull()
    expect(container.querySelector('.wk-goal-row')).not.toBeNull()
    expect(container.querySelector('.wk-goal-measure')).not.toBeNull()
    // Unrelated verification MUST NOT appear under goal-1
    expect(container.textContent).not.toContain('Unrelated Goal Task')
    expect(container.textContent).not.toContain('vr-unrelated-999')

    const tla = container.querySelector('.tla')
    expect(tla).not.toBeNull()
    expect(tla!.getAttribute('data-locked')).toBe('false')
    expect(tla!.textContent).toContain('conf-req-1')
    expect(tla!.textContent).toContain('crev-7')

    // Confirm sends real runtime_instance_id + real verification IDs (never synthetic fallbacks)
    const confirmBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('최종 완료 확정 (Confirm Completion)'),
    ) as HTMLButtonElement
    expect(confirmBtn).toBeDefined()
    confirmBtn.click()
    await flushUi()
    expect(postCalls[0]).toEqual({
      url: '/api/v1/goals/confirmation',
      body: {
        goal_id: 'goal-1',
        criterion_revision: 'crev-7',
        request_id: 'conf-req-1',
        verification_run_id: 'vrun-9',
        expected_operator_id: 'op-1',
        expected_runtime_instance_id: 'inst-real-777',
        expected_workspace: { base_path: '/ws/masc', masc_root: '/ws/masc/.masc' },
      },
    })

    // Clicking linked task jumps to /work/tasks/task-42
    const taskButtons = [...container.querySelectorAll('button')].filter((b) =>
      b.textContent?.includes('Build Goals tab'),
    )
    expect(taskButtons.length).toBeGreaterThan(0)
    taskButtons[0]!.click()
    expect(onNavigate).toHaveBeenCalledWith('/work/tasks/task-42')

    // The previous workspace's Goal and proof disappear while the new source is pending.
    const oldFetch = globalThis.fetch
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input).startsWith('/api/v1/dashboard/goals')) {
        return new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener('abort', () => reject(init.signal!.reason), { once: true })
        })
      }
      return oldFetch(input, init)
    }) as typeof fetch
    bumpSessionEpoch()
    await flushUi()
    expect(container.querySelector('.tla')).toBeNull()
    expect(container.textContent).not.toContain('Finish Layer 6 Work & Knowledge')
    expect(container.textContent).toContain('목표 목록 불러오는 중')
  })

  it('Goals shows independent verification progress without treating a failed or partial queue as empty', async () => {
    const goal = {
      id: 'goal-visible',
      title: 'Independent goal',
      phase: 'Executing',
      priority: 1,
      measure: { kind: 'done_when', condition: 'Independent response' },
      procedure: 'Return the goal first',
      linked_task_count: 1,
      tasks: [{ id: 'task-linked', title: 'Linked task', status: 'todo' }],
    }
    const request = {
      request_id: 'verification-live',
      task_id: 'task-linked',
      task_title: 'Linked task',
      review_observation: { state: 'running' },
    }
    let resolveVerification!: (response: Response) => void
    let verification = new Promise<Response>((resolve) => { resolveVerification = resolve })
    let goalReads = 0
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.startsWith('/api/v1/dashboard/goals')) {
        goalReads += 1
        return jsonResponse({ tree: [goal] })
      }
      if (url.startsWith('/api/v1/verification/requests')) return (await verification).clone()
      return jsonResponse({})
    }) as typeof fetch

    render(html`<${WorkWorkspace} subroute="goals" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    await flushUi()
    const panel = container.querySelector('[aria-label="연결 태스크 검증 판정"]')!
    const refresh = [...panel.querySelectorAll('button')]
      .find((button) => button.textContent?.trim() === '검증 다시 읽기')!
    const readAgain = async (body: unknown, status = 200) => {
      verification = Promise.resolve(jsonResponse(body, status))
      refresh.click()
      await flushUi()
    }
    const empty = '이 목표에 연결된 태스크의 대기 중인 검증 제출이 없습니다.'
    expect(container.querySelector('[aria-label="목표 목록"]')?.textContent).toContain(goal.title)
    expect(panel.querySelector('[role="status"] [data-inline-spinner]')).not.toBeNull()
    expect(panel.textContent).not.toContain(empty)

    resolveVerification(jsonResponse({ requests: [request], truncated: false }))
    await flushUi()
    expect(panel.textContent).toContain('검토 중')
    expect(panel.querySelector('button.wk-btn-ok')?.hasAttribute('disabled')).toBe(false)

    await readAgain({ requests: [], backlog_error: 'Primary backlog unavailable' })
    expect(panel.querySelector('[role="alert"]')?.textContent).toContain('Primary backlog unavailable')
    expect(panel.textContent).toContain(request.request_id)
    expect(panel.querySelector('button.wk-btn-ok')?.hasAttribute('disabled')).toBe(true)
    expect(panel.querySelector('[data-inline-spinner]')).toBeNull()
    expect(panel.textContent).not.toContain(empty)

    await readAgain({ error: { message: 'Verification temporarily unavailable' } }, 503)
    expect(panel.querySelector('[role="alert"]')?.textContent).toContain('검증 목록 조회 불가')
    expect(panel.textContent).not.toContain(empty)

    await readAgain({ requests: [], truncated: true })
    expect(panel.textContent).toContain('읽은 범위에 이 목표의 검증 제출이 없습니다.')
    expect(panel.textContent).not.toContain(empty)

    await readAgain({ requests: [], truncated: false })
    expect(panel.textContent).toContain(empty)
    expect(goalReads).toBe(1)
  })

  it('Goals keeps a missing selection empty and aborts an action whose read changes during precondition lookup', async () => {
    const goal = (id: string) => ({
      id,
      title: id,
      phase: 'Executing',
      priority: 1,
      measure: { kind: 'done_when', condition: 'Refresh Goal safely' },
      procedure: 'Invalidate the read before the transition',
      tasks: [],
    })
    let tree = [goal('goal-selected'), goal('goal-other')]
    let finishHealth!: (response: Response) => void
    const health = new Promise<Response>((resolve) => { finishHealth = resolve })
    const writes: string[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.startsWith('/api/v1/dashboard/goals')) return jsonResponse({ tree })
      if (url.startsWith('/api/v1/verification/requests')) return jsonResponse({ requests: [] })
      if (url.startsWith('/health?full=1')) return (await health).clone()
      if (init?.method === 'POST') writes.push(url)
      return jsonResponse({})
    }) as typeof fetch

    render(html`<${WorkWorkspace} subroute="goals" entityId="goal-selected" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    await flushUi()
    const transition = container.querySelector('[aria-label="목표 단계 전환"]')!
    const pause = [...transition.querySelectorAll('button')].find((button) => button.textContent?.trim() === '일시정지')!
    pause.click()
    resourceCache.invalidateTopic('goals')
    finishHealth(jsonResponse({
      build: { runtime_instance_id: 'test-instance' },
      paths: { effective_base_path: '/ws/masc', effective_masc_root: '/ws/masc/.masc' },
    }))
    await flushUi()
    expect(writes).toEqual([])
    expect(container.textContent).toContain('목표 정보가 변경되었습니다.')

    tree = [goal('goal-other')]
    const refresh = [...container.querySelectorAll('button')].find((button) => button.textContent?.trim() === '새로고침')!
    refresh.click()
    await flushUi()
    expect(container.querySelector('[aria-label="목표 단계 전환"]')).toBeNull()
    expect(container.querySelector('[aria-label="목표 목록"]')?.textContent).toContain('goal-other')
  })

  it('Goals tab skips /api/v1/verification/requests in multi_account_signed_in mode (0x 404)', async () => {
    setMultiAccountSessionForTest()
    const fetchedUrls: string[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      fetchedUrls.push(url)
      if (url.startsWith('/api/v1/dashboard/goals')) {
        return jsonResponse({
          tree: [
            {
              id: 'goal-ma',
              title: 'Multi-Account Goal',
              phase: 'Awaiting_confirmation',
              priority: 1,
              measure: { kind: 'done_when', condition: 'Zero 404s' },
              procedure: 'Check network requests',
              linked_task_count: 0,
              tasks: [],
            },
          ],
        })
      }
      return jsonResponse({ error: 'unexpected route' }, 404)
    }) as typeof fetch

    render(
      html`<${WorkWorkspace} subroute="goals" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi()

    expect(fetchedUrls.some((u) => u.startsWith('/api/v1/verification/requests'))).toBe(false)
    expect(fetchedUrls.some((u) => u.startsWith('/api/v1/goals/confirmation'))).toBe(false)
    expect(container.querySelector('[aria-label="목표 단계 전환"]')).toBeNull()
    expect(container.textContent).not.toContain('+ 새 목표')
    expect(container.textContent).toContain('Multi-Account Goal')
  })

  it('Tasks tab fetches cursor-paginated history with task_id + positive limit, handles 409 source changed, and aborts stale history fetch on rapid task switch', async () => {
    const requestedUrls: string[] = []
    let resolveSlowT1!: (resp: Response) => void
    const abortedTasks: string[] = []

    globalThis.fetch = vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      requestedUrls.push(url)
      if (url.startsWith('/api/v1/dashboard/planning')) {
        return Promise.resolve(jsonResponse({
          goals: [],
          tasks: [
            { id: 'task-99', title: 'Audit history cursor', status: 'in_progress', assignee: 'sangsu', priority: 1, goal_id: null },
            { id: 'task-100', title: 'Second task fast', status: 'todo', assignee: null, priority: 2, goal_id: null },
          ],
        }))
      }
      if (url.startsWith('/api/v1/dashboard/execution')) {
        return Promise.resolve(jsonResponse({ tasks: [] }))
      }
      if (url.startsWith('/api/v1/dashboard/scheduled-automation')) {
        return Promise.resolve(jsonResponse({ status: 'ok', schedule_store_known: true, schedule_store_read_error: null, request_count: 0, requests: [], truncated: false }))
      }
      if (url.startsWith('/api/v1/dashboard/tasks/history/page')) {
        if (url.includes('task_id=task-99') && !url.includes('cursor=')) {
          init?.signal?.addEventListener('abort', () => abortedTasks.push('task-99'))
          return new Promise<Response>((resolve) => {
            resolveSlowT1 = resolve
          })
        }
        if (url.includes('cursor=cur-2')) {
          return Promise.resolve(jsonResponse({ error: { code: 'task_history_source_changed', message: 'source rotated' } }, 409))
        }
        return Promise.resolve(jsonResponse({
          schema: 'masc.task-history.page/v2',
          task_id: 'task-100',
          cursor: null,
          sources: [{ source: 'backlog', state: 'observed' }],
          events: [{ source: 'backlog', file: 'tasks.jsonl', offset: 256, event: { kind: 'created_fast' } }],
          next_cursor: 'cur-2',
        }))
      }
      return Promise.resolve(jsonResponse({}))
    }) as typeof fetch

    render(
      html`<${WorkWorkspace} subroute="tasks" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(4)

    // Switch rapidly to task-100 while task-99 history is still pending
    const task100Btn = [...container.querySelectorAll('button.wk-row-btn')].find((b) =>
      b.textContent?.includes('Second task fast'),
    ) as HTMLButtonElement
    expect(task100Btn).toBeDefined()
    task100Btn.click()
    await flushUi(4)

    expect(abortedTasks).toContain('task-99')
    expect(container.textContent).toContain('created_fast')

    // Late resolution of task-99 history MUST NOT overwrite task-100
    resolveSlowT1(jsonResponse({
      schema: 'masc.task-history.page/v2',
      task_id: 'task-99',
      cursor: null,
      sources: [],
      events: [{ source: 'backlog', file: 'tasks.jsonl', offset: 128, event: { kind: 'STALE_TASK99_EVENT' } }],
      next_cursor: null,
    }))
    await flushUi(4)
    expect(container.textContent).toContain('created_fast')
    expect(container.textContent).not.toContain('STALE_TASK99_EVENT')

    const historyCalls = requestedUrls.filter((u) => u.startsWith('/api/v1/dashboard/tasks/history/page'))
    expect(historyCalls.some((u) => u.includes('task_id=task-100') && u.includes('limit=20'))).toBe(true)

    // Click load more -> triggers 409 task_history_source_changed banner
    const loadMoreBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('이전 이력 더 불러오기'),
    )
    expect(loadMoreBtn).toBeDefined()
    loadMoreBtn!.click()
    await flushUi()
    expect(container.textContent).toContain('409 task_history_source_changed')
  })

  it('Inbox shows ready sources during a slow Gate read and preserves audit availability independently', async () => {
    let finishGate!: (response: Response) => void
    let gateRead = new Promise<Response>((resolve) => {
      finishGate = resolve
    })
    const reads: string[] = []
    let approvalBody: unknown = {
      pending: [{ approval_id: 'approval-ready', tool_call_id: 'call-ready', keeper: 'fixture-sender', tool: 'fixture-tool' }],
    }
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      reads.push(url)
      if (url.startsWith('/api/v1/keepers/tool-approvals')) {
        return jsonResponse(approvalBody)
      }
      if (url.startsWith('/api/v1/keepers/asks')) return jsonResponse({ asks: [] })
      if (url.startsWith('/api/v1/dashboard/planning')) return jsonResponse({ goals: [] })
      if (url.startsWith('/api/v1/dashboard/gate')) return (await gateRead).clone()
      return jsonResponse({})
    }) as typeof fetch
    render(
      html`<${WorkWorkspace} subroute="inbox" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    const chip = (name: string) => [...container.querySelectorAll<HTMLButtonElement>('.wk-chip')]
      .find((element) => element.textContent?.trim().startsWith(name))!
    await flushUi()

    expect(container.querySelector('[aria-label="통합 HITL 대기열"]')?.textContent).toContain('fixture-tool')
    expect(container.querySelector('[role="status"] [data-inline-spinner]')).not.toBeNull()
    expect(chip('All Open').textContent).toContain('—')
    expect(container.querySelector<HTMLButtonElement>('.wk-btn-ok')?.disabled).toBe(false)

    finishGate(jsonResponse({
      approval_queue_state: { state: 'unavailable', operator_detail: 'Gate queue unavailable' },
      approval_queue: null,
      recent_resolved_state: { state: 'ready' },
      recent_resolved: [],
    }))
    await flushUi()
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('Gate queue unavailable')
    expect(container.querySelector('[aria-label="통합 HITL 대기열"]')?.textContent).toContain('fixture-tool')

    chip('24h Decisions').click()
    await flushUi()
    expect(container.textContent).toContain('최근 24시간 내 처리된 결정 기록이 없습니다.')
    expect(container.textContent).not.toContain('Gate queue unavailable')

    const approvalReads = reads.filter((url) => url.startsWith('/api/v1/keepers/tool-approvals')).length
    gateRead = Promise.resolve(jsonResponse({
      approval_queue_state: { state: 'ready' },
      approval_queue: [],
      recent_resolved_state: { state: 'unavailable', error: 'Audit temporarily unavailable' },
      recent_resolved: null,
    }))
    const refresh = [...container.querySelectorAll<HTMLButtonElement>('button')]
      .find((element) => element.textContent?.trim() === '새로고침')!
    refresh.click()
    await flushUi()
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('Channel Gate 결정 이력 조회 불가')
    expect(container.textContent).not.toContain('최근 24시간 내 처리된 결정 기록이 없습니다.')
    expect(reads.filter((url) => url.startsWith('/api/v1/keepers/tool-approvals'))).toHaveLength(approvalReads)
    chip('Channel Gate').click()
    await flushUi()
    expect(container.textContent).toContain('처리가 필요한 항목이 없습니다.')

    gateRead = Promise.resolve(jsonResponse({
      approval_queue: [],
      recent_resolved: [],
      recent_resolved_page: { scan_exhausted: true, truncated: false },
    }))
    chip('24h Decisions').click()
    refresh.click()
    await flushUi()
    expect(container.textContent).toContain('조회된 범위에 결정 기록이 없습니다.')
    expect(container.textContent).not.toContain('최근 24시간 내 처리된 결정 기록이 없습니다.')

    approvalBody = { pending: null }
    chip('Tool Approvals').click()
    await flushUi()
    refresh.click()
    await flushUi()
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('도구 승인 조회 불가')
    expect(container.textContent).not.toContain('처리가 필요한 항목이 없습니다.')
  })

  it('Unified Inbox wraps decisions in TargetLockedAction, drops earlier-epoch evidence, and allows clearing Keeper Ask drafts', async () => {
    const postCalls: { url: string; body: unknown }[] = []
    let waitForNewEpoch = false
    let approvalReceipt = { settled: true, remembered: false }
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (init?.method === 'POST') {
        postCalls.push({ url, body: init.body ? JSON.parse(String(init.body)) : null })
        return jsonResponse(approvalReceipt)
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
        if (waitForNewEpoch) return new Promise<Response>(() => {})
        return jsonResponse({
          scope: 'fleet',
          open_count: 1,
          asks: [
            {
              ask_id: 'ask-55',
              keeper: 'sangsu',
              revision: 'ask-rev-2',
              asked_at: '2026-11-24T05:30:00Z',
              resolution: { state: 'open' },
              questions: [
                {
                  question_id: 'q-choice',
                  header: 'Pick targets',
                  prompt: 'Choose one or more targets',
                  mode: 'multi',
                  choices: [{ choice_id: 'opt-a', label: 'Option A', description: null }],
                  free_text: { allowed: true, hint: null },
                },
                {
                  question_id: 'q-free',
                  header: 'Reason note',
                  prompt: 'Write a reason',
                  mode: 'single',
                  choices: [],
                  free_text: { allowed: true, hint: 'optional note' },
                },
              ],
            },
          ],
        })
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

    // 1. Tool Approval TargetLockedAction
    const tla = container.querySelector('.tla')
    expect(tla).not.toBeNull()
    expect(tla!.getAttribute('data-locked')).toBe('false')
    expect(tla!.textContent).toContain('default')
    expect(tla!.textContent).toContain('code-reviewer-sister')
    expect(tla!.textContent).toContain('appr-77')
    expect(tla!.textContent).toContain('rev-11')

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

    expect(container.textContent).toContain('승인됨')

    approvalReceipt = { settled: false, remembered: false }
    const retryApproval = [...container.querySelectorAll('button')].find((button) =>
      button.textContent?.includes('승인 (Approve)'),
    )!
    retryApproval.click()
    await flushUi()
    expect(container.textContent).toContain('결정 접수를 확인하지 못했습니다.')
    expect(container.textContent).not.toContain('승인됨')

    // 2. Switch to Keeper Ask and verify clearing free-text & deselecting last multi-choice
    const askRow = [...container.querySelectorAll('button.wk-row-btn')].find((b) =>
      b.textContent?.includes('Pick targets'),
    ) as HTMLButtonElement
    expect(askRow).toBeDefined()
    askRow.click()
    await flushUi(2)

    const optBtn = [...container.querySelectorAll('button.wk-chip')].find((b) =>
      b.textContent?.includes('Option A'),
    ) as HTMLButtonElement
    const freeInput = container.querySelector('#ask-text-q-free') as HTMLInputElement
    expect(optBtn).toBeDefined()
    expect(freeInput).not.toBeNull()

    // Select Option A -> aria-pressed true; click again -> deselected (aria-pressed false)
    optBtn.click()
    await flushUi(2)
    expect(optBtn.getAttribute('aria-pressed')).toBe('true')
    optBtn.click()
    await flushUi(2)
    expect(optBtn.getAttribute('aria-pressed')).toBe('false')

    // Type text then clear to "" -> input value becomes "" and submitting rejects missing answers without POSTing
    freeInput.value = 'Draft note'
    freeInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi(2)
    expect(freeInput.value).toBe('Draft note')

    freeInput.value = ''
    freeInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi(2)
    expect(freeInput.value).toBe('')

    const submitAskBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('답변 제출 (Submit Answer)'),
    ) as HTMLButtonElement
    expect(submitAskBtn).toBeDefined()
    submitAskBtn.click()
    await flushUi(2)
    expect(container.textContent).toContain('미응답 질문이 2개 있습니다.')
    expect(postCalls.some((c) => c.url === '/api/v1/keepers/ask-answer')).toBe(false)

    // 3. The prior Ask and its draft disappear while the new epoch reads.
    waitForNewEpoch = true
    bumpSessionEpoch()
    await flushUi(2)
    expect(container.textContent).not.toContain('Pick targets')
    expect(container.textContent).not.toContain('ask-55')
    expect(container.textContent).toContain('Keeper 질문 불러오는 중')
  })

  it('Unified Inbox skips single-user HITL endpoints in multi_account_signed_in mode (0x 404) while still loading Awaiting_confirmation goals', async () => {
    setMultiAccountSessionForTest()
    const fetchedUrls: string[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      fetchedUrls.push(url)
      if (url.startsWith('/api/v1/dashboard/planning')) {
        return jsonResponse({
          goals: [
            {
              id: 'goal-await-1',
              title: 'Awaiting Confirmation Goal',
              phase: 'Awaiting_confirmation',
              priority: 1,
              measure: { kind: 'done_when', condition: 'Ready' },
              procedure: 'Check',
              linked_task_count: 0,
            },
          ],
          tasks: [],
        })
      }
      return jsonResponse({ error: 'unexpected route' }, 404)
    }) as typeof fetch

    render(
      html`<${WorkWorkspace} subroute="inbox" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi()

    expect(fetchedUrls.some((u) => u.startsWith('/api/v1/keepers/tool-approvals'))).toBe(false)
    expect(fetchedUrls.some((u) => u.startsWith('/api/v1/keepers/asks'))).toBe(false)
    expect(fetchedUrls.some((u) => u.startsWith('/api/v1/dashboard/gate'))).toBe(false)
    expect(fetchedUrls.some((u) => u.startsWith('/api/v1/goals/confirmation'))).toBe(false)
    expect(fetchedUrls.some((u) => u.startsWith('/health?full=1'))).toBe(false)
    expect(container.textContent).toContain('Awaiting Confirmation Goal')
    expect(container.textContent).toContain('멀티 계정 모드')
  })

  it('Candle parses decimal-string *_milli vs numeric balance_milli, distinguishes absent vs 0, uses native progress gauge, and fires Hold Release', async () => {
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

    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
    vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:sangsu-candle-portrait')

    const releaseCalls: { url: string; body: unknown }[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.includes('/portrait.png')) {
        return new Response(new Blob(['png'], { type: 'image/png' }), {
          status: 200,
          headers: { 'Content-Type': 'image/png' },
        })
      }
      if (url.startsWith('/api/v1/candle/ledger')) {
        return jsonResponse({ schema_version: 1, instance_id: 'i1', generated_at_unix: 1, data: samplePayload })
      }
      if (url === '/health?full=1') {
        return jsonResponse({ paths: { effective_base_path: '/work', effective_masc_root: '/work/.masc' } })
      }
      if (url.startsWith('/api/v1/dashboard/goals/candle?')) {
        expect(new URLSearchParams(url.split('?')[1]).get('expected_masc_root')).toBe('/work/.masc')
        return jsonResponse({
          goal_id: 'goal-held-1',
          ledger: {
            state: 'observed',
            payout: { state: 'held', origin: 'stored', request_id: 'request-1', verification_run_id: 'verification-2' },
          },
        })
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
    expect(container.textContent).toContain('0.000')
    expect(container.textContent).toContain('sangsu')
    const portraitImg = container.querySelector('img.kb-portrait') as HTMLImageElement | null
    expect(portraitImg).not.toBeNull()
    expect(portraitImg?.getAttribute('src')).toBe('blob:sangsu-candle-portrait')
    const progressEl = container.querySelector('progress.wk-gauge') as HTMLProgressElement | null
    expect(progressEl).not.toBeNull()
    expect(progressEl!.getAttribute('style')).toBeNull()

    const findButton = (label: string) => [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.trim() === label,
    )
    const input = container.querySelector<HTMLInputElement>('[aria-label="Goal Candle 조회 ID"]')!
    expect(findButton('Hold Release')).toBeUndefined()
    findButton('보류 확인')!.click()
    await flushUi()

    const confirmation = container.querySelector('[data-request-id="request-1"]')
    expect(confirmation?.textContent).toContain('goal-held-1')
    expect(confirmation?.textContent).toContain('verification-2')

    input.value = 'another-goal'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()
    expect(findButton('Hold Release')).toBeUndefined()
    expect(releaseCalls).toHaveLength(0)

    findButton('보류 확인')!.click()
    await flushUi()
    findButton('Hold Release')!.click()
    await flushUi()
    expect(releaseCalls).toEqual([
      {
        url: '/api/v1/dashboard/goals/candle/hold/release',
        body: {
          goal_id: 'goal-held-1',
          expected_workspace: { base_path: '/work', masc_root: '/work/.masc' },
          expected_hold: { request_id: 'request-1', verification_run_id: 'verification-2' },
        },
      },
    ])
  })

  it('Tasks tab supports active_only=false schedules history toggle, truncation banner, and unlinked task verification verdicts', async () => {
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: true },
      workspaceId: 'default',
    }
    const requestedUrls: string[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      requestedUrls.push(url)
      if (url.startsWith('/api/v1/dashboard/planning')) {
        return jsonResponse({
          goals: [],
          tasks: [
            { id: 'task-unlinked-1', title: 'Standalone fix', status: 'awaiting_verification', assignee: 'sangsu', priority: 1, goal_id: null },
          ],
        })
      }
      if (url.startsWith('/api/v1/dashboard/execution')) return jsonResponse({ tasks: [] })
      if (url.startsWith('/api/v1/dashboard/tasks/history/page')) {
        return jsonResponse({ schema: 'masc.task-history.page/v2', task_id: 'task-unlinked-1', events: [], next_cursor: null })
      }
      if (url.startsWith('/api/v1/verification/requests')) {
        return jsonResponse({
          requests: [
            {
              request_id: 'vr-standalone-1',
              task_id: 'task-unlinked-1',
              task_title: 'Standalone fix',
              submitted_by: 'sangsu',
              created_at: '2026-11-25T01:00:00Z',
              review_observation: { state: 'rejected', detail: 'Missing regression test', actor: 'code-reviewer' },
            },
          ],
        })
      }
      if (url.includes('/api/v1/dashboard/scheduled-automation?active_only=false')) {
        return jsonResponse({
          status: 'ok',
          schedule_store_known: true,
          schedule_store_read_error: null,
          request_count: 50,
          truncated: true,
          requests: [
            {
              schedule_id: 'sched-hist-1',
              status: 'completed',
              payload_keeper_name: 'sangsu',
              payload_summary: 'Completed run',
              due_at: 1795478400,
              due_at_iso: '2026-11-24T00:00:00Z',
            },
          ],
        })
      }
      if (url.includes('/api/v1/dashboard/scheduled-automation?active_only=true')) {
        return jsonResponse({
          status: 'ok',
          schedule_store_known: true,
          schedule_store_read_error: null,
          request_count: 0,
          truncated: false,
          requests: [],
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${WorkWorkspace} subroute="tasks" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(4)

    expect(container.textContent).toContain('Verification Verdicts (1)')
    expect(container.textContent).toContain('rejected')
    expect(container.textContent).toContain('Missing regression test')

    const schedChip = [...container.querySelectorAll('button.wk-chip')].find((b) =>
      b.textContent?.startsWith('Schedules'),
    ) as HTMLButtonElement
    schedChip.click()
    await flushUi(3)

    const allHistBtn = [...container.querySelectorAll('button.wk-chip')].find((b) =>
      b.textContent?.trim() === '전체 이력',
    ) as HTMLButtonElement
    expect(allHistBtn).toBeDefined()
    allHistBtn.click()
    await flushUi(4)

    expect(requestedUrls.some((u) => u.includes('active_only=false'))).toBe(true)
    expect(container.textContent).toContain('Completed run')
    expect(container.textContent).toContain('표시 제한으로 일부만 표시됩니다 (1 / 50건)')
  })
})
