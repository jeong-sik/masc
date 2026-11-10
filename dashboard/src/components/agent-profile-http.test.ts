import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from '../api/core'
import { acceptedExecutionWorkspace } from '../execution-workspace-authority'
import { hydrateExecutionSnapshot, tasks } from '../store'
import { AgentProfile } from './agent-profile'

interface Read {
  path: string
  init: RequestInit
  scope: string
  body: { id: string; params: { name: string; arguments: Record<string, unknown> } } | null
  resolve: (response: Response) => void
}
const stamp = '2026-11-10T00:00:00Z'
let generation = 0
let profile = ''
let scope = 'A'
const reads: Read[] = []
const settle = () => act(async () => {
  await vi.advanceTimersByTimeAsync(0)
  await vi.dynamicImportSettled()
})
function workspace(label: string) {
  scope = label
  expect(hydrateExecutionSnapshot({ execution_publication_epoch: 'profile-http-owner',
    execution_publication_generation: ++generation, observer_instance_id: `profile-${label}`,
    projection_diagnostics: { read_completeness: 'complete', read_error: null },
    status: { project: 'profile', workspace_root: `/workspace-${label}` }, agents: [],
    tasks: [{ id: `${label}-task`, title: `${label} task`, assignee: profile, status: 'claimed' }],
    messages: [], keepers: [], execution_queue: [], worker_support_briefs: [], continuity_briefs: [],
  })).toBe(true)
}
function answer(read: Read): Response {
  if (read.body) {
    const text = read.body.params.name === 'masc_messages'
      ? `${profile} ${read.scope}-activity`
      : `${read.scope}-history`
    return Response.json({ jsonrpc: '2.0', id: read.body.id,
      result: { content: [{ type: 'text', text }] } })
  }
  const agent = new URL(read.path, 'http://fixture').searchParams.get('agent_name')!
  return Response.json({ agent, period: { from: stamp, to: stamp },
    events: [{ ts: stamp, type: 'task_completed', detail: { title: `${agent}-${read.scope}-timeline` } }],
    summary: { tasks_completed: read.scope === 'A' ? 731 : 947, tasks_claimed: 1,
      messages_sent: 1, active_duration_minutes: 1, total_events: 1 } })
}
function installFetch(pending: (read: Read) => boolean = () => false) {
  vi.stubGlobal('fetch', vi.fn((path: string, init: RequestInit) => {
    if (path !== '/mcp' && !path.startsWith('/api/v1/agent-timeline?')) {
      throw new Error(`Unexpected request: ${path}`)
    }
    const body: Read['body'] = path === '/mcp' ? JSON.parse(String(init.body)) : null
    if (body) expect(['masc_messages', 'masc_task_history']).toContain(body.params.name)
    let resolve!: Read['resolve']
    const promise = new Promise<Response>(complete => { resolve = complete })
    const read: Read = { path, init, scope, body, resolve }
    reads.push(read)
    if (!pending(read)) resolve(answer(read))
    return promise
  }))
}
function expectNoAData() {
  for (const value of ['A-activity', 'A-history', 'A-timeline', '731']) {
    expect(screen.queryByText(new RegExp(value))).toBeNull()
  }
}

beforeEach(({ task }) => {
  vi.useFakeTimers()
  localStorage.clear()
  setStoredToken('profile-credential', { source: 'manual' })
  profile = `profile-${task.id}`
  reads.length = 0
  workspace('A')
})
afterEach(() => {
  cleanup()
  acceptedExecutionWorkspace.value = null
  clearStoredToken()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe('AgentProfile actual read ownership', () => {
  it('withdraws activity, history, timeline and summary while a same-name B read is pending or refused', async () => {
    installFetch(read => read.scope === 'B')
    render(html`<${AgentProfile} name=${profile} />`)
    await settle()
    expect(document.body.textContent).toContain('A-activity')
    expect(screen.queryByText('A-history')).not.toBeNull()
    expect(screen.queryByText(`${profile}-A-timeline`)).not.toBeNull()
    expect(screen.queryByText('731')).not.toBeNull()
    await act(async () => { workspace('B') })
    expectNoAData()
    await settle()
    const pending = reads.filter(read => read.scope === 'B')
    expect(pending).toHaveLength(2)
    await act(async () => { for (const read of pending) read.resolve(Response.json({ error: 'access refused' }, { status: 403 })) })
    await settle()
    expectNoAData()
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(reads).toHaveLength(5)
  })

  it('physically cancels both A transports and cannot start A task reads or install late A data under B', async () => {
    installFetch(read => read.scope === 'A')
    render(html`<${AgentProfile} name=${profile} />`)
    await settle()
    const original = [...reads]
    expect(original).toHaveLength(2)
    await act(async () => { workspace('B') })
    await settle()
    expect(original.map(read => read.init.signal?.aborted)).toEqual([true, true])
    expect(screen.queryByText(new RegExp('B-activity'))).not.toBeNull()
    await act(async () => { for (const read of original) read.resolve(answer(read)) })
    await settle()
    expectNoAData()
    const history = reads.filter(read => read.body?.params.name === 'masc_task_history')
    expect(history.map(read => read.body?.params.arguments.task_id)).toEqual(['B-task'])
  })

  it('does not issue requests without an accepted workspace and resumes one profile read when it is accepted', async () => {
    acceptedExecutionWorkspace.value = null
    installFetch()
    render(html`<${AgentProfile} name=${profile} />`)
    await settle()
    expect(reads).toHaveLength(0)
    await act(async () => { workspace('B') })
    await settle()
    expect(reads).toHaveLength(3)
    expect(screen.queryByText(new RegExp('B-activity'))).not.toBeNull()
  })

  it('cancels a disposed name before a replacement profile loads and rejects its late response', async () => {
    installFetch(read => !read.body && new URL(read.path, 'http://fixture').searchParams.get('agent_name') === profile
      || read.body?.params.name === 'masc_messages' && reads.filter(item => item.body?.params.name === 'masc_messages').length === 1)
    const view = render(html`<${AgentProfile} name=${profile} />`)
    await settle()
    const original = [...reads]
    const nextName = `${profile}-replacement`
    await act(async () => { view.rerender(html`<${AgentProfile} name=${nextName} />`) })
    await settle()
    expect(original.map(read => read.init.signal?.aborted)).toEqual([true, true])
    await act(async () => { for (const read of original) read.resolve(answer(read)) })
    await settle()
    expect(screen.queryByText(new RegExp('A-activity'))).toBeNull()
    expect(screen.queryByText(`${profile}-A-timeline`)).toBeNull()
    expect(screen.queryByText(`${nextName}-A-timeline`)).not.toBeNull()
    expect(reads.filter(read => read.body?.params.name === 'masc_task_history')).toHaveLength(0)
  })

  it('physically cancels pending HTTP and MCP reads on unmount', async () => {
    installFetch(() => true)
    const view = render(html`<${AgentProfile} name=${profile} />`)
    await settle()
    const original = [...reads]
    expect(original).toHaveLength(2)
    view.unmount()
    expect(original.map(read => read.init.signal?.aborted)).toEqual([true, true])
    await act(async () => { for (const read of original) read.resolve(answer(read)) })
    await settle()
    expect(reads).toHaveLength(2)
  })

  it('uses the task IDs captured before its initial reads yielded', async () => {
    installFetch(read => read.body?.params.name === 'masc_messages')
    render(html`<${AgentProfile} name=${profile} />`)
    await settle()
    const originalMessages = reads.find(read => read.body?.params.name === 'masc_messages')!
    tasks.value = [{ id: 'newer-task', title: 'newer task', assignee: profile, status: 'claimed' }]
    await act(async () => { originalMessages.resolve(answer(originalMessages)) })
    await settle()
    const history = reads.filter(read => read.body?.params.name === 'masc_task_history')
    expect(history.map(read => read.body?.params.arguments.task_id)).toEqual(['A-task'])
  })

  it('cancels an in-flight history on credential replacement and keeps manual refresh available', async () => {
    installFetch(read => read.body?.params.name === 'masc_task_history' && read.scope === 'A')
    render(html`<${AgentProfile} name=${profile} />`)
    await settle()
    const original = reads.find(read => read.body?.params.name === 'masc_task_history')!
    expect(original).toBeDefined()
    scope = 'B'
    await act(async () => { setStoredToken('replacement-credential', { source: 'manual' }) })
    await settle()
    expect(original.init.signal?.aborted).toBe(true)
    expect(screen.queryByText('B-history')).not.toBeNull()
    await act(async () => { original.resolve(answer(original)) })
    await settle()
    expect(screen.queryByText('A-history')).toBeNull()
    const before = reads.length
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await settle()
    expect(reads.length).toBe(before + 3)
  })
})
