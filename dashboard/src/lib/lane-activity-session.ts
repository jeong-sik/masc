import { effect, signal } from '@preact/signals'
import {
  fetchRuntimeTomlConfig, previewRuntimeTomlConfig, saveRuntimeTomlConfig,
  RuntimeTomlRevisionConflict, RuntimeTomlSaveRejected, type RuntimeTomlCurrentSource, type RuntimeTomlConfig,
  type CommittedRuntimeTomlConfig,
} from '../api/dashboard-runtime'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'
import { announceRuntimeTomlWritten, announceRuntimeTomlWriteUncertain, runtimeTomlSourceGeneration } from './runtime-toml-source-generation'
import { errorToString } from './format-string'
import type { ModelSetupResumeState } from './model-setup-resume'
import { refreshRuntimeConfigConsumers } from './runtime-config-refresh'
import { announceRuntimeTomlCommitted } from './runtime-toml-session'

export type LaneActivityDocument = RuntimeTomlCurrentSource
export type LaneActivityDraft = { base: LaneActivityDocument; enabled: boolean }
/** One activity save. `checking` covers the preview and the token wait, when
 * the file cannot change; the raw POST's beforeDispatch moves it to `sent`;
 * the turn its response settles moves it to `answered`, or to `committed`
 * when that response is a verified commit whose durability is unconfirmed.
 * `source` is the text it submits, so a later read can tell whether that
 * write landed. */
export type SaveAttempt = { stage: 'checking' | 'sent' | 'answered' | 'committed'; readonly source: string }
/** Server activity for lanes that report it apart from the file. A `reading`
 * value is identified by object identity, so any later read, save or
 * workspace change that replaces it also discards its late response. */
export type LaneActivityObservation<O> =
  | { kind: 'unknown' } | { kind: 'reading' } | { kind: 'failed'; error: string } | ({ kind: 'observed' } & O)
export type LaneActivityPhase = 'idle' | 'reading' | 'saving' | 'followup'
export type LaneActivityState<O> = {
  draft: LaneActivityDraft | null; current: LaneActivityDocument | null; phase: LaneActivityPhase;
  error: string | null; notice: string | null; followupError: string | null; setupResumeError: string | null;
  receipt: CommittedRuntimeTomlConfig | null;
  /** The save whose write outcome is unknown; null when no write is in doubt. */
  uncertain: SaveAttempt | null;
  observation: LaneActivityObservation<O>;
}

/** What differs between Lane kinds. Everything else -- workspace ownership,
 * the dispatch boundary, uncertainty and its settlement -- is the session's. */
export type LaneActivitySpec<L, O> = {
  /** Keeps one session per workspace and lane. */
  key(lane: L): string
  read(source: string, lane: L): { enabled: boolean }
  write(source: string, lane: L, enabled: boolean): string
  /** Work owed after a committed save, before consumers refresh. Returns a
   * setup-resume failure to show, or null. Aborted when ownership moves. */
  afterCommit?(signal: AbortSignal): Promise<string | null>
  announceObservation(authority: ExecutionWorkspaceAuthority): void
  /** Server activity for this lane; a rejection becomes a failed observation. */
  observe?(lane: L): Promise<LaneActivityObservation<O>>
}

type Registered = {
  dirty(): boolean
  invalidate(authority: ExecutionWorkspaceAuthority | null, generation: number): void
  completeSetupResume(authority: ExecutionWorkspaceAuthority, result: ModelSetupResumeState): void
}
const registries: Array<() => Iterable<Registered>> = []
function* allSessions(): Iterable<Registered> { for (const sessions of registries) yield* sessions() }

let guardingUnload = false
const beforeUnload = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
function syncUnloadGuard() {
  const dirty = [...allSessions()].some(session => session.dirty())
  if (typeof window === 'undefined' || dirty === guardingUnload) return
  guardingUnload = dirty
  if (dirty) window.addEventListener('beforeunload', beforeUnload)
  else window.removeEventListener('beforeunload', beforeUnload)
}
function document(config: RuntimeTomlConfig): LaneActivityDocument {
  if (!config.ok || config.path === null || config.path === '' || !/^[0-9a-f]{64}$/.test(config.source_revision))
    throw new Error('현재 runtime.toml 파일과 저장 기준을 확인하지 못했습니다.')
  return { source_path: config.path, source_text: config.source_text, source_revision: config.source_revision }
}
const unobserved = { kind: 'unknown' } as const

/** An activity draft owns only a boolean. It never adopts or overwrites the
 * full raw editor's independent draft, including when that editor is hidden. */
export class LaneActivitySession<L, O> {
  readonly expanded = signal(false)
  readonly state = signal<LaneActivityState<O>>({ draft: null, current: null, phase: 'idle', error: null, notice: null,
    followupError: null, setupResumeError: null, receipt: null, uncertain: null, observation: unobserved })
  private authority: ExecutionWorkspaceAuthority | null = null
  private attempt: SaveAttempt | null = null
  private followup: AbortController | null = null
  private version = 0
  private generation = runtimeTomlSourceGeneration.peek()
  constructor(private readonly spec: LaneActivitySpec<L, O>, readonly workspaceRoot: string, readonly lane: L) {}
  private update(change: Partial<LaneActivityState<O>>) { this.state.value = { ...this.state.peek(), ...change }; syncUnloadGuard() }
  admits(authority: ExecutionWorkspaceAuthority) {
    return authority.workspaceRoot === this.workspaceRoot && executionWorkspaceAuthority.peek() === authority
  }
  ready(authority: ExecutionWorkspaceAuthority) {
    return this.admits(authority) && this.authority === authority && this.state.peek().phase === 'idle'
      && this.state.peek().current !== null
  }
  modified() {
    const draft = this.state.peek().draft
    return draft !== null && this.spec.read(draft.base.source_text, this.lane).enabled !== draft.enabled
  }
  dirty() {
    const { uncertain, phase } = this.state.peek()
    return this.modified() || uncertain !== null || phase === 'saving' || phase === 'followup'
  }
  completeSetupResume(authority: ExecutionWorkspaceAuthority, result: ModelSetupResumeState) {
    if (result.kind === 'active' && this.admits(authority) && this.authority === authority) {
      this.update({ setupResumeError: null })
    }
  }
  invalidate(authority: ExecutionWorkspaceAuthority | null, generation: number) {
    const before = this.state.peek()
    if (this.authority !== null && this.authority !== authority) {
      ++this.version; this.authority = null; this.followup?.abort()
      // Only a sent POST can have changed the file; a save still in preview or
      // the token wait is stopped by beforeDispatch once ownership moves.
      const unanswered = this.attempt?.stage === 'sent' ? this.attempt : null
      this.update({ phase: 'idle', current: null, observation: unobserved, uncertain: before.uncertain ?? unanswered,
        error: '작업공간 연결이 바뀌었습니다. 초안은 보관했습니다. 현재 설정을 다시 읽으세요.' })
    }
    if (generation !== this.generation) {
      this.generation = generation
      if (this.authority === authority && before.draft !== null) this.update({ current: null, observation: unobserved,
        notice: '다른 화면의 설정 변경 요청으로 현재 파일 확인이 필요합니다. 초안은 그대로입니다. 현재 설정을 다시 읽으세요.' })
    }
  }
  private owns(authority: ExecutionWorkspaceAuthority, version: number) {
    return this.admits(authority) && this.authority === authority && this.version === version
  }
  private options(authority: ExecutionWorkspaceAuthority, version: number) {
    return { beforeDispatch: () => {
      if (!this.owns(authority, version)) throw new Error('작업공간 또는 요청이 바뀌어 전송을 중지했습니다.')
    } }
  }
  /** The file read alone gates editing; a server observation settles on its
   * own. The promise resolves when both have settled. */
  async read(authority: ExecutionWorkspaceAuthority): Promise<void> {
    if (!this.admits(authority) || this.state.peek().phase !== 'idle') return
    this.authority = authority
    const version = ++this.version
    const sourceGeneration = runtimeTomlSourceGeneration.peek()
    const observe = this.spec.observe
    const observation: LaneActivityObservation<O> = observe ? { kind: 'reading' } : unobserved
    this.update({ phase: 'reading', current: null, observation, error: null })
    await Promise.all([this.readFile(authority, version, sourceGeneration),
      observe ? this.observe(observe, observation) : undefined])
  }
  private async observe(observe: (lane: L) => Promise<LaneActivityObservation<O>>, pending: LaneActivityObservation<O>) {
    let settled: LaneActivityObservation<O>
    try { settled = await observe(this.lane) }
    catch (error) { settled = { kind: 'failed', error: `서버 활동 조회 실패: ${errorToString(error)}` } }
    if (this.state.peek().observation === pending) this.update({ observation: settled })
  }
  private async readFile(authority: ExecutionWorkspaceAuthority, version: number, sourceGeneration: number): Promise<void> {
    let superseded = false
    try {
      const file = await fetchRuntimeTomlConfig(this.options(authority, version))
      if (!this.owns(authority, version)) return
      if (sourceGeneration !== runtimeTomlSourceGeneration.peek()) { superseded = true; return }
      const current = document(file)
      const activity = this.spec.read(current.source_text, this.lane)
      this.generation = runtimeTomlSourceGeneration.peek()
      this.update({ current, ...this.settleRead(current, activity.enabled) })
    } catch (error) {
      if (this.owns(authority, version)) this.update({ error: errorToString(error) })
    } finally {
      if (this.owns(authority, version)) {
        this.update({ phase: 'idle' })
        if (superseded) await this.read(authority)
      }
    }
  }
  /** What a successful read decides about the draft and an uncertain write.
   * The read is the evidence: an unchanged base revision means the write did
   * not replace the file, and a file holding exactly the submitted text means
   * an unanswered write did. A committed write whose durability is unconfirmed
   * is not settled by seeing its text, which proves visibility, not
   * durability. Any other file keeps the doubt until the draft is reapplied
   * to it or discarded, and save stays refused meanwhile. */
  private settleRead(current: LaneActivityDocument, enabled: boolean): Partial<LaneActivityState<O>> {
    const { draft, uncertain } = this.state.peek()
    const fresh = { base: current, enabled }
    if (uncertain === null) {
      const retain = draft !== null && (this.modified() || draft.base.source_path !== current.source_path)
      return { draft: retain ? draft : fresh, notice: null }
    }
    if (draft !== null && draft.base.source_path === current.source_path) {
      if (draft.base.source_revision === current.source_revision)
        return { draft, uncertain: null, notice: '이전 저장은 파일을 바꾸지 않았습니다. 초안을 다시 저장할 수 있습니다.' }
      if (current.source_text === uncertain.source)
        return uncertain.stage === 'committed'
          ? { draft, notice: '저장한 내용이 파일에 보이지만 디스크 반영은 확인되지 않았습니다. 활동 값만 다시 적용해 확정하세요.' }
          : { draft: fresh, uncertain: null, notice: '이전 저장이 파일에 반영된 것을 확인했습니다.' }
    }
    return { draft, notice: '파일이 다른 내용으로 바뀌었습니다. 이전 저장 결과를 확인할 수 없습니다. 활동 값만 다시 적용하거나 초안을 버리세요.' }
  }
  toggle(authority: ExecutionWorkspaceAuthority) {
    const { draft, current } = this.state.peek()
    if (!this.ready(authority) || !draft || !current) return
    try {
      if (draft.base.source_path !== current.source_path) throw new Error('파일 경로가 바뀌었습니다. 초안을 버린 뒤 새 파일을 편집하세요.')
      this.spec.write(draft.base.source_text, this.lane, !draft.enabled)
      this.update({ draft: { ...draft, enabled: !draft.enabled }, error: null, notice: null, receipt: null })
    } catch (error) { this.update({ error: errorToString(error) }) }
  }
  reapply(authority: ExecutionWorkspaceAuthority) {
    const { draft, current } = this.state.peek()
    if (!this.ready(authority) || !draft || !current) return
    try {
      if (draft.base.source_path !== current.source_path) throw new Error('다른 파일에는 기존 초안을 재적용할 수 없습니다. 먼저 초안을 버리세요.')
      this.spec.write(current.source_text, this.lane, draft.enabled)
      this.update({ draft: { ...draft, base: current }, uncertain: null, error: null,
        notice: '활동 값만 현재 설정에 다시 적용했습니다. 저장 버튼으로 확정하세요.' })
    } catch (error) { this.update({ error: errorToString(error) }) }
  }
  discard(authority: ExecutionWorkspaceAuthority) {
    if (!this.admits(authority) || this.state.peek().phase !== 'idle') return
    const current = this.state.peek().current
    this.update({ draft: current ? { base: current, enabled: this.spec.read(current.source_text, this.lane).enabled } : null,
      uncertain: current === null ? this.state.peek().uncertain : null,
      error: null, notice: '초안을 버렸습니다. 파일은 변경하지 않았습니다.' })
  }
  async save(authority: ExecutionWorkspaceAuthority): Promise<boolean> {
    const { draft, current, uncertain } = this.state.peek()
    if (!this.ready(authority) || !draft || !current || !this.modified()) return false
    if (uncertain !== null) {
      this.update({ error: '이전 저장 결과가 불확실합니다. 현재 파일을 확인하고 활동 값만 다시 적용하거나 초안을 버리세요.' }); return false
    }
    if (draft.base.source_path !== current.source_path || draft.base.source_revision !== current.source_revision) {
      this.update({ error: '파일이 바뀌었습니다. 활동 값만 다시 적용하거나 초안을 버리세요.' }); return false
    }
    let source: string
    try { source = this.spec.write(draft.base.source_text, this.lane, draft.enabled) }
    catch (error) { this.update({ error: errorToString(error) }); return false }
    const version = ++this.version, options = this.options(authority, version)
    const sourceGeneration = runtimeTomlSourceGeneration.peek()
    const attempt: SaveAttempt = { stage: 'checking', source }
    let committed = false
    this.attempt = attempt
    this.update({ phase: 'saving', error: null, notice: null, followupError: null, setupResumeError: null })
    try {
      const preview = await previewRuntimeTomlConfig(source, options)
      if (!this.owns(authority, version)) return false
      if (!preview.ok || !preview.can_save) throw new Error('설정 검증에서 저장을 거절했습니다. Runtime 설정에서 원문과 오류를 확인하세요.')
      const receipt = await saveRuntimeTomlConfig(source, draft.base.source_revision, { expectedSourcePath: draft.base.source_path, beforeDispatch: () => {
        options.beforeDispatch()
        if (sourceGeneration !== runtimeTomlSourceGeneration.peek()) throw new Error('다른 화면에서 설정이 변경됐습니다. 현재 설정을 다시 읽으세요.')
        attempt.stage = 'sent'
      } })
      attempt.stage = 'answered'
      if (!this.owns(authority, version)) return false
      const saved = document(receipt)
      if (saved.source_path !== draft.base.source_path || saved.source_text !== source || receipt.commit.source_revision !== saved.source_revision)
        throw new Error('저장 응답이 제출한 파일과 일치하지 않습니다. 현재 설정을 다시 읽으세요.')
      committed = true
      if (receipt.commit.durability !== 'durable') attempt.stage = 'committed'
      announceRuntimeTomlWritten()
      this.update({ phase: 'followup', receipt, current: null, observation: unobserved,
        uncertain: receipt.commit.durability === 'durable' ? null : attempt,
        draft: receipt.commit.durability === 'durable' ? { ...draft, base: saved } : draft,
        notice: '파일 저장 응답을 받았습니다. 현재 설정과 적용 상태를 다시 확인합니다.' })
      const controller = new AbortController(); this.followup = controller
      const setupResumeError = this.spec.afterCommit ? await this.spec.afterCommit(controller.signal) : null
      if (!this.owns(authority, version)) return false
      announceRuntimeTomlCommitted(authority)
      this.spec.announceObservation(authority)
      if (setupResumeError !== null) this.update({ setupResumeError })
      try { await refreshRuntimeConfigConsumers() }
      catch (error) { if (this.owns(authority, version)) this.update({ followupError:
        [this.state.peek().followupError, `설정 저장 후 목록 갱신 실패: ${errorToString(error)}`].filter(Boolean).join(' ') }) }
    } catch (error) {
      if (attempt.stage === 'sent') attempt.stage = 'answered'
      const sent = attempt.stage === 'answered'
      if (this.owns(authority, version)) {
        if (error instanceof RuntimeTomlRevisionConflict) {
          try {
            const conflictCurrent = sourceGeneration === runtimeTomlSourceGeneration.peek() ? error.current : null
            if (conflictCurrent) this.spec.read(conflictCurrent.source_text, this.lane)
            this.update({ current: conflictCurrent, uncertain: null, error: conflictCurrent
              ? '파일이 바뀌어 저장하지 않았습니다. 초안은 보관했습니다.'
              : '파일이 바뀌어 저장하지 않았습니다. 다른 변경도 관측되어 현재 설정을 다시 읽으세요.' })
          } catch (cause) { this.update({ current: null, uncertain: null, error: errorToString(cause) }) }
        } else if (error instanceof RuntimeTomlSaveRejected) {
          this.update({ uncertain: null,
            error: `${errorToString(error)} 저장 전에 거절되었습니다. 초안과 저장 기준은 유지됩니다.` })
        } else this.update({ current: sent || sourceGeneration !== runtimeTomlSourceGeneration.peek() ? null : current,
          observation: sent ? unobserved : this.state.peek().observation, uncertain: sent ? attempt : this.state.peek().uncertain,
          error: errorToString(error) + (sent ? ' 저장 결과가 불확실합니다. 현재 설정을 다시 읽으세요.' : '') })
      } else if ((error instanceof RuntimeTomlRevisionConflict || error instanceof RuntimeTomlSaveRejected)
        && this.state.peek().uncertain === attempt) {
        // The server answered this attempt without replacing the file. The
        // conflict document belongs to the old authority and is not adopted;
        // invalidate() already cleared `current`, so a read must precede any save.
        this.update({ uncertain: null })
      }
    } finally {
      if (this.attempt === attempt) this.attempt = null
      if (this.owns(authority, version)) { this.followup = null; this.update({ phase: 'idle' }) }
    }
    if (committed && this.owns(authority, version)) await this.read(authority)
    else if (this.state.peek().uncertain === attempt && this.owns(authority, version)) {
      // The file may have changed. Other screens hear so; this draft waits for
      // an operator read, since a read racing the unanswered write would
      // misjudge it.
      announceRuntimeTomlWriteUncertain(); this.spec.announceObservation(authority)
    }
    return committed && this.admits(authority)
  }
}

/** One registry per Lane kind; the unload guard and invalidation cover all. */
export function laneActivitySessions<L, O = never>(spec: LaneActivitySpec<L, O>) {
  const sessions = new Map<string, LaneActivitySession<L, O>>()
  registries.push(() => sessions.values())
  return {
    sessionFor(authority: ExecutionWorkspaceAuthority, lane: L): LaneActivitySession<L, O> {
      const key = JSON.stringify([authority.workspaceRoot, spec.key(lane)])
      let session = sessions.get(key)
      if (!session) { session = new LaneActivitySession(spec, authority.workspaceRoot, lane); sessions.set(key, session) }
      return session
    },
    resetForTesting() { sessions.clear(); syncUnloadGuard() },
  }
}

export function completeLaneActivitySetupResume(authority: ExecutionWorkspaceAuthority, result: ModelSetupResumeState) {
  for (const session of allSessions()) session.completeSetupResume(authority, result)
}

effect(() => {
  const authority = executionWorkspaceAuthority.value, generation = runtimeTomlSourceGeneration.value
  for (const session of allSessions()) session.invalidate(authority, generation)
})
