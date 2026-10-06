import { createHash } from 'node:crypto'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { RuntimeTomlRevisionConflict, RuntimeTomlSaveRejected, type RuntimeTomlConfig } from '../api/dashboard-runtime'
import { executionWorkspaceAuthority, hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration, type ExecutionWorkspaceAuthority } from '../store'
import { committedRuntimeTomlConfigFixture } from './runtime-config-receipt.test-fixture'
import { runtimeTomlSourceGeneration } from './runtime-toml-source-generation'
import { laneActivitySessions, type LaneActivitySpec } from './lane-activity-session'
import { modelSetupResumeState, resumeSavedModelSetup } from './model-setup-resume'

const api = vi.hoisted(() => ({ fetchRuntimeTomlConfig: vi.fn(), previewRuntimeTomlConfig: vi.fn(), saveRuntimeTomlConfig: vi.fn() }))
const settings = vi.hoisted(() => ({ announceRuntimeTomlCommitted: vi.fn() }))
const consumers = vi.hoisted(() => ({ refreshRuntimeConfigConsumers: vi.fn() }))
const core = vi.hoisted(() => ({ post: vi.fn() }))
vi.mock('../api/core', async original => ({ ...await original<typeof import('../api/core')>(), ...core }))
vi.mock('../api/dashboard-runtime', async original => ({ ...await original<typeof import('../api/dashboard-runtime')>(), ...api }))
vi.mock('./runtime-toml-session', async original => ({ ...await original<typeof import('./runtime-toml-session')>(), ...settings }))
vi.mock('./runtime-config-refresh', () => consumers)

// A one-line activity per lane: `<lane> = true|false`. Other lines are kept.
const line = (lane: string, enabled: boolean) => `${lane} = ${enabled}`
const read = (text: string, lane: string) => ({ enabled: text.split('\n').includes(line(lane, true)) })
const write = (text: string, lane: string, enabled: boolean) =>
  text.split('\n').map(row => row.startsWith(`${lane} = `) ? line(lane, enabled) : row).join('\n')
const observations = vi.fn()
const afterCommit = vi.fn<(signal: AbortSignal) => Promise<string | null>>()
const spec: LaneActivitySpec<string, never> = { key: lane => lane, read, write, afterCommit, announceObservation: observations }
const fakes = laneActivitySessions(spec)
const others = laneActivitySessions<string>({ key: lane => lane, read, write, announceObservation: () => undefined })

const path = '/workspace/runtime.toml'
const base = 'alpha = true\nbeta = true\n# kept\n'
const revision = (text: string) => createHash('sha256').update(text).digest('hex')
const config = (text: string): RuntimeTomlConfig => ({ ok: true, path, file_name: 'runtime.toml', source_text: text,
  source_revision: revision(text), provider_protocols: [], reserved_provider_ids: [] })
function receipt(text: string, durability: 'durable' | 'unconfirmed' = 'durable') {
  const value = committedRuntimeTomlConfigFixture({ ...config(text), path })
  value.source_revision = revision(text); value.commit.source_revision = revision(text); value.commit.durability = durability
  return value
}
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(done => { resolve = done }); return { promise, resolve } }
function rejectable<T>() { let reject!: (error: unknown) => void; const promise = new Promise<T>((_, fail) => { reject = fail }); return { promise, reject } }
type SaveOptions = { beforeDispatch?: () => void; expectedSourcePath: string }

let stored = base, epoch = 0, generation = 0
function workspace(root: string): ExecutionWorkspaceAuthority {
  hydrateExecutionSnapshot({ execution_publication_epoch: `lane-activity-${epoch}`, execution_publication_generation: ++generation,
    status: { project: 'fixture', workspace_root: root } } as Parameters<typeof hydrateExecutionSnapshot>[0])
  return executionWorkspaceAuthority.peek()!
}
beforeEach(() => {
  vi.resetAllMocks(); fakes.resetForTesting(); others.resetForTesting(); stored = base
  modelSetupResumeState.value = { kind: 'idle' }
  ++epoch; generation = 0; invalidateExecutionSnapshotGeneration(`lane-activity-${epoch}`, 0); workspace('/fixture/A')
  api.fetchRuntimeTomlConfig.mockImplementation(async () => config(stored))
  api.previewRuntimeTomlConfig.mockResolvedValue({ ok: true, can_save: true })
  api.saveRuntimeTomlConfig.mockImplementation(async (text: string, expected: string, options: SaveOptions) => {
    options.beforeDispatch?.()
    if (expected !== revision(stored)) throw new RuntimeTomlRevisionConflict('changed', { source_path: path, source_text: stored, source_revision: revision(stored) })
    stored = text; return receipt(text)
  })
  afterCommit.mockResolvedValue(null)
  consumers.refreshRuntimeConfigConsumers.mockResolvedValue(undefined)
})
afterEach(() => { fakes.resetForTesting(); others.resetForTesting() })
async function draft(lane = 'alpha') {
  const authority = executionWorkspaceAuthority.peek()!, session = fakes.sessionFor(authority, lane)
  await session.read(authority); session.toggle(authority)
  return { authority, session }
}

describe('Lane activity session', () => {
  it.each(['preview', 'before dispatch'] as const)('keeps a save certain when ownership moves at %s', async moment => {
    const { authority, session } = await draft()
    const gate = deferred<void>()
    if (moment === 'preview') api.previewRuntimeTomlConfig.mockImplementationOnce(async () => { await gate.promise; return { ok: true, can_save: true } })
    else api.saveRuntimeTomlConfig.mockImplementationOnce(async (_text: string, _expected: string, options: SaveOptions) => {
      await gate.promise; options.beforeDispatch?.(); throw new Error('unreachable')
    })
    const saving = session.save(authority)
    workspace('/fixture/B'); gate.resolve()
    expect(await saving).toBe(false)
    expect(session.state.value.uncertain).toBeNull()
    expect(stored).toBe(base)
  })

  it.each([
    ['a known refusal', (): unknown => new RuntimeTomlSaveRejected('refused before replacement'), null],
    ['a revision conflict', (): unknown => new RuntimeTomlRevisionConflict('changed', { source_path: path, source_text: base, source_revision: revision(base) }), null],
    ['a lost connection', (): unknown => new Error('connection reset'), 'answered'],
  ] as const)('marks a dispatched save uncertain and settles a late answer by its kind: %s', async (_label, failure, uncertainAfter) => {
    const { authority, session } = await draft()
    const answer = rejectable<never>()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async (_text: string, _expected: string, options: SaveOptions) => {
      options.beforeDispatch?.(); return answer.promise
    })
    const saving = session.save(authority)
    await vi.waitFor(() => expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    workspace('/fixture/B')
    expect(session.state.value.uncertain?.stage).toBe('sent')
    answer.reject(failure())
    expect(await saving).toBe(false)
    expect(session.state.value.uncertain?.stage ?? null).toBe(uncertainAfter)
    expect(session.state.value.current).toBeNull()
  })

  it.each([
    ['unchanged file', (): string => base, /아직 저장 전 그대로/, true],
    ['submitted text', (): string => stored, /보낸 내용이 파일에 보입니다/, false],
    ['another change', (): string => base.replace('# kept', '# edited elsewhere'), /다른 내용으로 바뀌었습니다/, true],
  ] as const)('keeps an unanswered write in doubt after a read and says what the file shows: %s', async (_label, file, notice, pendingAfterReapply) => {
    const { authority, session } = await draft()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async (text: string, _expected: string, options: SaveOptions) => {
      options.beforeDispatch?.(); stored = text; throw new Error('connection lost')
    })
    expect(await session.save(authority)).toBe(false)
    expect(session.state.value.uncertain?.stage).toBe('answered')
    expect(session.state.value.current).toBeNull()
    const reads = api.fetchRuntimeTomlConfig.mock.calls.length
    stored = file()
    await session.read(authority)
    expect(api.fetchRuntimeTomlConfig.mock.calls.length).toBe(reads + 1)
    expect(session.state.value.uncertain?.stage).toBe('answered')
    expect(session.state.value.notice).toMatch(notice)
    expect(await session.save(authority)).toBe(false)
    session.reapply(authority)
    expect(session.state.value.uncertain).toBeNull()
    expect(session.modified()).toBe(pendingAfterReapply)
  })

  it('does not reread after an unanswered write but tells other screens the file may have changed', async () => {
    const { authority, session } = await draft()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async (_text: string, _expected: string, options: SaveOptions) => {
      options.beforeDispatch?.(); throw new Error('connection lost')
    })
    const reads = api.fetchRuntimeTomlConfig.mock.calls.length, sourceGeneration = runtimeTomlSourceGeneration.peek()
    expect(await session.save(authority)).toBe(false)
    expect(api.fetchRuntimeTomlConfig.mock.calls.length).toBe(reads)
    expect(runtimeTomlSourceGeneration.peek()).toBe(sourceGeneration + 1)
    expect(observations).toHaveBeenCalledWith(authority)
    expect(session.state.value.notice).toBeNull()
  })

  it.each([
    ['unchanged file', (): string => base, /아직 저장 전 그대로/],
    ['submitted text', (): string => stored, /보낸 내용이 파일에 보입니다/],
    ['another change', (): string => base.replace('# kept', '# edited elsewhere'), /다른 내용으로 바뀌었습니다/],
  ] as const)('rebuilds a draft after a discard left none, compared with the saved-over file: %s', async (_label, file, notice) => {
    const { authority, session } = await draft()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async (text: string, _expected: string, options: SaveOptions) => {
      options.beforeDispatch?.(); stored = text; throw new Error('connection lost')
    })
    expect(await session.save(authority)).toBe(false)
    session.discard(authority)
    expect(session.state.value.draft).toBeNull()
    expect(session.state.value.uncertain?.stage).toBe('answered')
    stored = file()
    await session.read(authority)
    expect(session.state.value.uncertain?.stage).toBe('answered')
    expect(session.state.value.notice).toMatch(notice)
    expect(session.state.value.draft?.base.source_text).toBe(stored)
    session.reapply(authority)
    expect(session.state.value.uncertain).toBeNull()
  })

  it('keeps doubt when the saved-over text is read from another file path', async () => {
    const { authority, session } = await draft()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async (_text: string, _expected: string, options: SaveOptions) => {
      options.beforeDispatch?.(); throw new Error('connection lost')
    })
    expect(await session.save(authority)).toBe(false)
    api.fetchRuntimeTomlConfig.mockResolvedValueOnce({ ...config(base), path: '/elsewhere/runtime.toml' })
    await session.read(authority)
    expect(session.state.value.uncertain?.stage).toBe('answered')
    expect(session.state.value.notice).toMatch(/다른 내용으로 바뀌었습니다/)
  })

  it('clears an earlier notice when a later read fails', async () => {
    const { authority, session } = await draft()
    session.discard(authority)
    expect(session.state.value.notice).toMatch(/초안을 버렸습니다/)
    api.fetchRuntimeTomlConfig.mockRejectedValueOnce(new Error('runtime.toml unavailable'))
    await session.read(authority)
    expect(session.state.value.notice).toBeNull()
    expect(session.state.value.error).toMatch(/runtime.toml unavailable/)
  })

  it('keeps a committed write with unconfirmed durability in doubt until it is reapplied', async () => {
    const { authority, session } = await draft()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async (text: string, _expected: string, options: SaveOptions) => {
      options.beforeDispatch?.(); stored = text; return receipt(text, 'unconfirmed')
    })
    expect(await session.save(authority)).toBe(true)
    expect(session.state.value.current?.source_text).toBe(stored)
    expect(session.state.value.uncertain?.stage).toBe('answered')
    expect(session.state.value.notice).toMatch(/보낸 내용이 파일에 보입니다/)
    expect(session.state.value.draft?.base.source_text).toBe(base)
    expect(await session.save(authority)).toBe(false)
    session.reapply(authority)
    expect(session.state.value.uncertain).toBeNull()
    expect(session.modified()).toBe(false)
    expect(session.state.value.notice).toMatch(/저장할 변경이 없습니다/)
  })

  it('keeps an unconfirmed commit in doubt when the file no longer shows it', async () => {
    const { authority, session } = await draft()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async (text: string, _expected: string, options: SaveOptions) => {
      options.beforeDispatch?.(); return receipt(text, 'unconfirmed')
    })
    expect(await session.save(authority)).toBe(true)
    expect(session.state.value.uncertain?.stage).toBe('answered')
    expect(session.state.value.notice).toMatch(/아직 저장 전 그대로/)
    session.reapply(authority)
    expect(session.state.value.uncertain).toBeNull()
    expect(session.modified()).toBe(true)
  })

  it('announces a commit to Settings and the lane observers after its follow-up', async () => {
    afterCommit.mockResolvedValueOnce('setup resume unconfirmed')
    const { authority, session } = await draft()
    expect(await session.save(authority)).toBe(true)
    expect(afterCommit).toHaveBeenCalledTimes(1)
    expect(settings.announceRuntimeTomlCommitted).toHaveBeenCalledWith(authority)
    expect(observations).toHaveBeenCalledWith(authority)
    expect(session.state.value.setupResumeError).toBe('setup resume unconfirmed')
    expect(session.state.value.uncertain).toBeNull()
    expect(stored).toBe(write(base, 'alpha', false))
  })

  it('reports a failure after a durable commit as a follow-up error, not a write in doubt', async () => {
    afterCommit.mockRejectedValueOnce(new Error('resume crashed'))
    const { authority, session } = await draft()
    expect(await session.save(authority)).toBe(true)
    expect(session.state.value.uncertain).toBeNull()
    expect(session.state.value.followupError).toMatch(/resume crashed/)
    expect(session.state.value.notice).toBeNull()
  })

  it('clears a setup-resume error only when the latest resume succeeds, from any screen', async () => {
    const active = { runtime_ready: true, exact_output_authority_available: true, model_setup: { status: 'available' } }
    afterCommit.mockResolvedValueOnce('setup resume unconfirmed')
    const { authority, session } = await draft()
    expect(await session.save(authority)).toBe(true)
    expect(session.state.value.setupResumeError).toBe('setup resume unconfirmed')
    const older = deferred<unknown>()
    core.post.mockReturnValueOnce(older.promise).mockRejectedValueOnce(new Error('activation failed'))
    const first = resumeSavedModelSetup(), second = resumeSavedModelSetup()
    expect((await second).kind).toBe('failed')
    older.resolve(active)
    expect((await first).kind).toBe('active')
    expect(session.state.value.setupResumeError).toBe('setup resume unconfirmed')
    core.post.mockResolvedValueOnce(active)
    expect((await resumeSavedModelSetup()).kind).toBe('active')
    expect(session.state.value.setupResumeError).toBeNull()
  })

  it('aborts the follow-up when ownership moves and leaves a durable commit certain', async () => {
    const resume = deferred<string | null>()
    let aborted = false
    afterCommit.mockImplementationOnce(async signal => { signal.addEventListener('abort', () => { aborted = true }); return resume.promise })
    const { authority, session } = await draft()
    const saving = session.save(authority)
    await vi.waitFor(() => expect(afterCommit).toHaveBeenCalledTimes(1))
    workspace('/fixture/B'); resume.resolve(null)
    expect(await saving).toBe(false)
    expect(aborted).toBe(true)
    expect(session.state.value.uncertain).toBeNull()
    expect(settings.announceRuntimeTomlCommitted).not.toHaveBeenCalled()
  })

  it('keeps a revision conflict certain and retains the draft', async () => {
    const { authority, session } = await draft()
    stored = base.replace('# kept', '# edited elsewhere')
    expect(await session.save(authority)).toBe(false)
    expect(session.state.value.uncertain).toBeNull()
    expect(session.state.value.current?.source_text).toBe(stored)
    expect(session.state.value.error).toMatch(/파일이 바뀌어 저장하지 않았습니다/)
    expect(session.modified()).toBe(true)
  })

  it('guards page exit for a dirty session of any Lane kind', async () => {
    const add = vi.spyOn(window, 'addEventListener'), remove = vi.spyOn(window, 'removeEventListener')
    const authority = executionWorkspaceAuthority.peek()!, other = others.sessionFor(authority, 'beta')
    await other.read(authority); other.toggle(authority)
    expect(add).toHaveBeenCalledWith('beforeunload', expect.any(Function))
    other.discard(authority)
    expect(remove).toHaveBeenCalledWith('beforeunload', expect.any(Function))
  })
})
