import { effect, signal } from '@preact/signals'
import { fetchRuntimeTomlConfig, type CommittedRuntimeTomlConfig, type RuntimeTomlConfig } from '../api/dashboard'
import { RuntimeTomlRevisionConflict, type RuntimeTomlCurrentSource, type RuntimeTomlRequestOptions } from '../api/dashboard-runtime'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'
import { runtimeTomlSourceGeneration } from './runtime-toml-source-generation'
import { runtimeConfigCommitReceiptNotice } from './runtime-config-receipt'
import { resumeSavedModelSetup } from './model-setup-resume'
import { refreshRuntimeConfigConsumers } from './runtime-config-refresh'
import { errorToString } from './format-string'

export type RuntimeSectionId = 'routing' | 'lanes' | 'providers' | 'models' | 'bindings' | 'assignments' | 'toml'
type Phase = 'idle' | 'loading' | 'reading' | 'saving_raw' | 'saving_patch'
const isSaving = (phase: Phase) => phase === 'saving_raw' || phase === 'saving_patch'
type State = {
  config: RuntimeTomlConfig | null; draft: string; modelContextDrafts: Record<string, string>;
  currentSource: RuntimeTomlCurrentSource | null; phase: Phase; needsRead: boolean; uncertainWrite: boolean;
  section: RuntimeSectionId; error: string | null; notice: string | null; projectionRevision: number;
}
const sessions = new Map<string, RuntimeTomlSession>()
const isDirty = (state: State) => Object.keys(state.modelContextDrafts).length > 0
  || state.config !== null && state.draft !== state.config.source_text
let guardingUnload = false
const beforeUnload = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
function syncUnloadGuard() {
  const dirty = [...sessions.values()].some(session => {
    const state = session.state.peek()
    return isDirty(state) || isSaving(state.phase) || state.uncertainWrite
  })
  if (typeof window === 'undefined' || guardingUnload === dirty) return
  guardingUnload = dirty
  if (dirty) window.addEventListener('beforeunload', beforeUnload)
  else window.removeEventListener('beforeunload', beforeUnload)
}

/** Owns a workspace's resolved runtime file and its revision across UI mounts.
 * A changed resolved path is not adopted over a retained draft by a comparison
 * read. Only an explicit reload/discard may select a different file. */
export class RuntimeTomlSession {
  readonly committed = signal<{ authority: ExecutionWorkspaceAuthority; generation: number } | null>(null)
  readonly state = signal<State>({ config: null, draft: '', modelContextDrafts: {}, currentSource: null,
    phase: 'idle', needsRead: false, uncertainWrite: false, section: 'routing', error: null, notice: null, projectionRevision: 0 })
  private basisAuthority: ExecutionWorkspaceAuthority | null = null
  private generation = runtimeTomlSourceGeneration.peek()
  private resumeController: AbortController | null = null
  constructor(readonly workspaceRoot: string) {}
  admits(authority: ExecutionWorkspaceAuthority) {
    return authority.workspaceRoot === this.workspaceRoot && executionWorkspaceAuthority.peek() === authority
  }
  ready(authority: ExecutionWorkspaceAuthority) {
    return this.admits(authority) && this.basisAuthority === authority && !this.state.peek().needsRead
  }
  writable(authority: ExecutionWorkspaceAuthority) {
    return this.ready(authority) && !this.state.peek().uncertainWrite
  }
  update(change: Partial<State>) {
    this.state.value = { ...this.state.peek(), ...change }
    syncUnloadGuard()
  }
  edit<K extends keyof State>(key: K, value: State[K] | ((current: State[K]) => State[K])) {
    if (this.state.peek().phase === 'saving_patch' && (key === 'draft' || key === 'modelContextDrafts')) return
    const next = typeof value === 'function' ? value(this.state.peek()[key]) : value
    if (Object.is(next, this.state.peek()[key])) return
    this.update({ [key]: next })
  }
  requestOptions(authority: ExecutionWorkspaceAuthority): RuntimeTomlRequestOptions {
    return { beforeDispatch: () => {
      if (!this.admits(authority)) throw new Error('작업공간이 바뀌어 요청을 보내지 않았습니다.')
    } }
  }
  invalidate(authority: ExecutionWorkspaceAuthority | null, generation: number) {
    const state = this.state.peek()
    if (this.basisAuthority !== null && this.basisAuthority !== authority) {
      this.resumeController?.abort()
      // Do not clear the operation phase: its original request still owns it.
      if (!state.needsRead || state.currentSource !== null) this.changedAuthority()
    }
    if (authority?.workspaceRoot === this.workspaceRoot && generation !== this.generation) {
      this.generation = generation
      if (state.config !== null) this.update({ needsRead: true, currentSource: null,
        projectionRevision: state.projectionRevision + 1,
        error: 'runtime.toml 이 다른 화면에서 저장되었습니다. 초안은 유지됩니다. 현재 파일을 읽고 비교한 뒤 저장 기준을 선택하세요.' })
    }
  }
  private changedAuthority() {
    this.update({ needsRead: true, currentSource: null,
      uncertainWrite: this.state.peek().uncertainWrite || isSaving(this.state.peek().phase),
      error: '작업공간 연결이 바뀌었습니다. 초안은 유지됩니다. 현재 파일을 읽고 비교한 뒤 저장 기준을 선택하세요.' })
  }
  async ensure(authority: ExecutionWorkspaceAuthority) {
    if (!this.admits(authority) || this.state.peek().phase !== 'idle') return
    const state = this.state.peek()
    if (state.config === null) await this.read(authority, 'reload')
    else if (this.basisAuthority !== authority) await this.read(authority, 'revalidate')
    else if (state.needsRead && !isDirty(state)) await this.read(authority, 'reload')
  }
  async read(authority: ExecutionWorkspaceAuthority, mode: 'reload' | 'compare' | 'revalidate') {
    if (!this.admits(authority) || this.state.peek().phase !== 'idle') return
    const before = this.state.peek()
    const generation = runtimeTomlSourceGeneration.peek()
    let superseded = false
    this.update({ phase: mode === 'reload' ? 'loading' : 'reading', error: null, notice: null })
    try {
      const current = await fetchRuntimeTomlConfig(this.requestOptions(authority))
      if (!this.admits(authority)) { this.changedAuthority(); return }
      if (generation !== runtimeTomlSourceGeneration.peek()) {
        superseded = true
        this.update({ needsRead: true, currentSource: null,
          error: '읽는 동안 runtime.toml이 변경되었습니다. 현재 파일을 다시 읽고 비교하세요.' })
        return
      }
      if (mode !== 'reload' && (current.path === null || current.path !== before.config?.path)) {
        this.update({ needsRead: true, currentSource: null })
        throw new Error('현재 파일 경로가 편집 중인 runtime.toml과 다릅니다. 초안을 복사하거나 명시적으로 다시 불러오세요.')
      }
      this.basisAuthority = authority
      this.generation = runtimeTomlSourceGeneration.peek()
      if (mode === 'reload') this.update({ config: current, draft: current.source_text, modelContextDrafts: {},
        currentSource: null, needsRead: false, uncertainWrite: false })
      else if (mode === 'revalidate' && current.source_revision === before.config?.source_revision) {
        this.update({ config: current, currentSource: null, needsRead: false, uncertainWrite: false,
          notice: '파일이 바뀌지 않았습니다. 보관된 초안을 복구했습니다.' })
      }
      else this.update({ currentSource: { source_path: current.path!, source_text: current.source_text,
        source_revision: current.source_revision }, needsRead: false, section: 'toml',
        notice: '현재 파일을 읽었습니다. 초안과 저장 기준은 바뀌지 않았습니다.' })
    } catch (error) {
      if (!this.admits(authority)) this.changedAuthority()
      else this.update({ error: `${errorToString(error)} 초안과 저장 기준은 유지됩니다.` })
    } finally { this.update({ phase: 'idle' })
      // Invalidation effects may have run while this request owned the phase.
      // Revalidate the current authority, never the retired request's token.
      const currentAuthority = executionWorkspaceAuthority.peek()
      if (currentAuthority?.workspaceRoot === this.workspaceRoot
        && (superseded || currentAuthority !== authority)) await this.ensure(currentAuthority)
    }
  }
  useCurrent(authority: ExecutionWorkspaceAuthority, replaceDraft: boolean) {
    const state = this.state.peek(), current = state.currentSource
    if (!this.ready(authority) || state.phase !== 'idle' || state.config === null || current === null
      || current.source_path !== state.config.path) return
    this.update({ config: { ...state.config, source_text: current.source_text, source_revision: current.source_revision },
      ...(replaceDraft ? { draft: current.source_text, modelContextDrafts: {} } : {}), currentSource: null, error: null, uncertainWrite: false,
      notice: replaceDraft ? '표시된 현재 원문으로 초안을 교체했습니다.'
        : '표시된 현재 revision을 저장 기준으로 채택했습니다. 초안은 유지됩니다. 다음 저장은 이 초안으로 현재 파일을 교체합니다.' })
  }
  async write(authority: ExecutionWorkspaceAuthority,
    send: (options: RuntimeTomlRequestOptions) => Promise<CommittedRuntimeTomlConfig | { unchanged: RuntimeTomlConfig }>, submittedText?: string): Promise<boolean> {
    const before = this.state.peek()
    if (!this.writable(authority) || before.phase !== 'idle' || before.config === null || before.currentSource !== null
      || Object.keys(before.modelContextDrafts).length > 0 || submittedText === undefined && isDirty(before)) return false
    const submitted = submittedText ?? before.draft
    this.update({ phase: submittedText === undefined ? 'saving_patch' : 'saving_raw', error: null, notice: null })
    try {
      const result = await send(this.requestOptions(authority))
      const saved = 'unchanged' in result ? result.unchanged : result
      if (!this.admits(authority)) { this.changedAuthority(); return false }
      if (before.config.path !== null && saved.path !== before.config.path) {
        this.update({ needsRead: true, currentSource: null })
        throw new Error('저장 응답의 파일 경로가 편집 중인 runtime.toml과 다릅니다.')
      }
      const latest = this.state.peek()
      this.update({ config: saved, draft: latest.draft === before.draft ? saved.source_text : latest.draft,
        currentSource: null, uncertainWrite: false, notice: !('unchanged' in result)
          ? runtimeConfigCommitReceiptNotice(result)
            + (latest.draft !== submitted && latest.draft !== before.draft ? ' 저장 중 추가한 초안은 저장되지 않았습니다.' : '')
          : 'runtime assignment unchanged' })
      if ('unchanged' in result) return false
      // Unmount does not interrupt the saved file's session. A different
      // workspace does prevent follow-up writes to model setup.
      if (!this.admits(authority)) return true
      const controller = new AbortController()
      this.resumeController = controller
      await resumeSavedModelSetup({ signal: controller.signal })
      if (!this.admits(authority)) return true
      // Setup resume may publish the registry for the first time after the
      // file receipt. Editors that remounted during this write must reread it.
      this.update({ projectionRevision: this.state.peek().projectionRevision + 1 })
      announceRuntimeTomlCommitted(authority)
      try { await refreshRuntimeConfigConsumers() }
      catch (error) { if (this.admits(authority)) this.update({ error: `대시보드 런타임 갱신 실패: ${errorToString(error)}` }) }
      return true
    } catch (error) {
      if (!this.admits(authority)) this.changedAuthority()
      else if (error instanceof RuntimeTomlRevisionConflict && error.current.source_path === before.config.path) {
        this.update({ currentSource: error.current, section: 'toml',
          error: `${error.message} 저장하지 않았습니다. 초안과 기존 저장 기준을 유지했습니다.` })
      } else this.update({ uncertainWrite: true, error: `${errorToString(error)} 초안은 유지됩니다. 파일 변경 여부를 확인하지 못했습니다. 현재 파일을 읽고 비교한 뒤 다시 저장하세요.` })
      return false
    } finally { this.resumeController = null; this.update({ phase: 'idle' }) }
  }
}

export function runtimeTomlSessionFor(authority: ExecutionWorkspaceAuthority): RuntimeTomlSession {
  let session = sessions.get(authority.workspaceRoot)
  if (!session) { session = new RuntimeTomlSession(authority.workspaceRoot); sessions.set(authority.workspaceRoot, session) }
  return session
}
/** Notify mounted settings of an owned file commit without adopting its raw draft. */
export function announceRuntimeTomlCommitted(authority: ExecutionWorkspaceAuthority) {
  const session = runtimeTomlSessionFor(authority)
  if (!session.admits(authority)) return
  session.committed.value = { authority, generation: runtimeTomlSourceGeneration.peek() }
}
// Keep dirty/uncertain documents guarded even while every editor is unmounted.
effect(() => {
  const authority = executionWorkspaceAuthority.value, generation = runtimeTomlSourceGeneration.value
  for (const session of sessions.values()) session.invalidate(authority, generation)
})
export function resetRuntimeTomlSessionsForTesting() { sessions.clear(); syncUnloadGuard() }
