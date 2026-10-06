import { effect, signal } from '@preact/signals'
import {
  fetchRuntimeTomlConfig, previewRuntimeTomlConfig, saveRuntimeTomlConfig,
  RuntimeTomlRevisionConflict, RuntimeTomlSaveRejected, type RuntimeTomlCurrentSource, type RuntimeTomlConfig,
  type CommittedRuntimeTomlConfig,
} from '../api/dashboard-runtime'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'
import { announceRuntimeTomlWritten, runtimeTomlSourceGeneration } from './runtime-toml-source-generation'
import { readMachineActivity, writeMachineActivity, type MachineActivityLane } from './machine-lane-activity'
import { errorToString } from './format-string'
import { refreshRuntimeConfigConsumers } from './runtime-config-refresh'
import { announceMachineLaneObservationChanged } from './machine-lane-observation'
import { fetchLaneInventory, type LaneInventoryRow } from '../api/lane-inventory'

type Document = RuntimeTomlCurrentSource
type Draft = { base: Document; enabled: boolean }
/** Server activity from the lane inventory. It settles apart from the file
 * read; a `reading` value is identified by object identity, so any later read,
 * save or workspace change that replaces it also discards its late response. */
type Observation =
  | { kind: 'unknown' } | { kind: 'reading' } | { kind: 'failed'; error: string }
  | { kind: 'observed'; activity: Extract<LaneInventoryRow['state'], { kind: 'machine' }>['activity']; at: number }
/** One activity save. `checking` covers preview and the token wait, when the
 * file cannot change; the raw POST's beforeDispatch moves it to `sent`; the
 * turn its response settles moves it to `answered`. */
type SaveAttempt = { stage: 'checking' | 'sent' | 'answered' }
type State = {
  draft: Draft | null; current: Document | null; phase: 'idle' | 'reading' | 'saving' | 'followup';
  error: string | null; notice: string | null; followupError: string | null;
  receipt: CommittedRuntimeTomlConfig | null;
  /** The save whose write outcome is unknown; null when no write is in doubt. */
  uncertain: SaveAttempt | null;
  observation: Observation;
}
const unobserved: Observation = { kind: 'unknown' }
const sessions = new Map<string, MachineLaneActivitySession>()
let guardingUnload = false
const beforeUnload = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
function syncUnloadGuard() {
  const dirty = [...sessions.values()].some(session => session.modified() || session.state.peek().uncertain !== null
    || session.state.peek().phase === 'saving')
  if (typeof window === 'undefined' || dirty === guardingUnload) return
  guardingUnload = dirty
  if (dirty) window.addEventListener('beforeunload', beforeUnload)
  else window.removeEventListener('beforeunload', beforeUnload)
}
function document(config: RuntimeTomlConfig): Document {
  if (!config.ok || config.path === null || config.path === '' || !/^[0-9a-f]{64}$/.test(config.source_revision))
    throw new Error('현재 runtime.toml 파일과 저장 기준을 확인하지 못했습니다.')
  return { source_path: config.path, source_text: config.source_text, source_revision: config.source_revision }
}

/** An activity draft owns only a boolean. It never adopts or overwrites the
 * full raw editor's independent draft, including when that editor is hidden. */
export class MachineLaneActivitySession {
  readonly expanded = signal(false)
  readonly state = signal<State>({ draft: null, current: null, phase: 'idle', error: null, notice: null, followupError: null, receipt: null, uncertain: null, observation: unobserved })
  private authority: ExecutionWorkspaceAuthority | null = null
  private attempt: SaveAttempt | null = null
  private version = 0
  private generation = runtimeTomlSourceGeneration.peek()
  constructor(readonly workspaceRoot: string, readonly lane: MachineActivityLane) {}
  private update(change: Partial<State>) { this.state.value = { ...this.state.peek(), ...change }; syncUnloadGuard() }
  admits(authority: ExecutionWorkspaceAuthority) {
    return authority.workspaceRoot === this.workspaceRoot && executionWorkspaceAuthority.peek() === authority
  }
  ready(authority: ExecutionWorkspaceAuthority) {
    return this.admits(authority) && this.authority === authority && this.state.peek().phase === 'idle'
      && this.state.peek().current !== null
  }
  modified() {
    const draft = this.state.peek().draft
    return draft !== null && readMachineActivity(draft.base.source_text, this.lane).enabled !== draft.enabled
  }
  invalidate(authority: ExecutionWorkspaceAuthority | null, generation: number) {
    const before = this.state.peek()
    if (this.authority !== null && this.authority !== authority) {
      ++this.version; this.authority = null
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
  /** The file read alone gates editing; the server observation settles on
   * its own. The promise resolves when both have settled. */
  async read(authority: ExecutionWorkspaceAuthority): Promise<void> {
    if (!this.admits(authority) || this.state.peek().phase !== 'idle') return
    this.authority = authority
    const version = ++this.version
    const observation: Observation = { kind: 'reading' }
    const sourceGeneration = runtimeTomlSourceGeneration.peek()
    this.update({ phase: 'reading', current: null, observation, error: null })
    await Promise.all([this.readFile(authority, version, sourceGeneration), this.observe(observation)])
  }
  private async observe(pending: Observation): Promise<void> {
    let settled: Observation
    try {
      const inventory = await fetchLaneInventory()
      const row = inventory.rows.find(row => row.selection.kind === 'machine' && row.selection.machine === this.lane)
      settled = row?.state.kind === 'machine' ? { kind: 'observed', activity: row.state.activity, at: inventory.observed_at }
        : { kind: 'failed', error: '현재 목록에서 선택한 기계를 확인하지 못했습니다.' }
    } catch (error) { settled = { kind: 'failed', error: `서버 활동 조회 실패: ${errorToString(error)}` } }
    if (this.state.peek().observation === pending) this.update({ observation: settled })
  }
  private async readFile(authority: ExecutionWorkspaceAuthority, version: number, sourceGeneration: number): Promise<void> {
    let superseded = false
    try {
      const file = await fetchRuntimeTomlConfig(this.options(authority, version))
      if (!this.owns(authority, version)) return
      if (sourceGeneration !== runtimeTomlSourceGeneration.peek()) { superseded = true; return }
      const current = document(file)
      const activity = readMachineActivity(current.source_text, this.lane)
      const before = this.state.peek()
      const retainDraft = before.draft !== null && (this.modified() || before.uncertain !== null
        || before.draft.base.source_path !== current.source_path)
      this.generation = runtimeTomlSourceGeneration.peek()
      this.update({ current, notice: null,
        draft: retainDraft ? before.draft : { base: current, enabled: activity.enabled } })
    } catch (error) {
      if (this.owns(authority, version)) this.update({ error: errorToString(error) })
    } finally {
      if (this.owns(authority, version)) {
        this.update({ phase: 'idle' })
        if (superseded) await this.read(authority)
      }
    }
  }
  toggle(authority: ExecutionWorkspaceAuthority) {
    const { draft, current } = this.state.peek()
    if (!this.ready(authority) || !draft || !current) return
    try {
      if (draft.base.source_path !== current.source_path) throw new Error('파일 경로가 바뀌었습니다. 초안을 버린 뒤 새 파일을 편집하세요.')
      writeMachineActivity(draft.base.source_text, this.lane, !draft.enabled)
      this.update({ draft: { ...draft, enabled: !draft.enabled }, error: null, notice: null, receipt: null })
    } catch (error) { this.update({ error: errorToString(error) }) }
  }
  reapply(authority: ExecutionWorkspaceAuthority) {
    const { draft, current } = this.state.peek()
    if (!this.ready(authority) || !draft || !current) return
    try {
      if (draft.base.source_path !== current.source_path) throw new Error('다른 파일에는 기존 초안을 재적용할 수 없습니다. 먼저 초안을 버리세요.')
      writeMachineActivity(current.source_text, this.lane, draft.enabled)
      this.update({ draft: { ...draft, base: current }, uncertain: null, error: null,
        notice: '활동 값만 현재 설정에 다시 적용했습니다. 저장 버튼으로 확정하세요.' })
    } catch (error) { this.update({ error: errorToString(error) }) }
  }
  discard(authority: ExecutionWorkspaceAuthority) {
    if (!this.admits(authority) || this.state.peek().phase !== 'idle') return
    const current = this.state.peek().current
    this.update({ draft: current ? { base: current, enabled: readMachineActivity(current.source_text, this.lane).enabled } : null,
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
    try { source = writeMachineActivity(draft.base.source_text, this.lane, draft.enabled) }
    catch (error) { this.update({ error: errorToString(error) }); return false }
    const version = ++this.version, options = this.options(authority, version)
    const sourceGeneration = runtimeTomlSourceGeneration.peek()
    const attempt: SaveAttempt = { stage: 'checking' }
    let committed = false
    this.attempt = attempt
    this.update({ phase: 'saving', error: null, notice: null, followupError: null })
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
      announceRuntimeTomlWritten()
      this.update({ phase: 'followup', receipt, current: null, observation: unobserved, uncertain: receipt.commit.durability === 'durable' ? null : attempt,
        draft: receipt.commit.durability === 'durable' ? { ...draft, base: saved } : draft,
        notice: '파일 저장 응답을 받았습니다. 현재 설정과 적용 상태를 다시 확인합니다.' })
      // Raw save publishes machine activity; model setup resume cannot load
      // or restore a machine. A receipt alone is not an owner observation.
      announceMachineLaneObservationChanged(authority)
      try { await refreshRuntimeConfigConsumers() }
      catch (error) { if (this.owns(authority, version)) this.update({ followupError:
        [this.state.peek().followupError, `설정 저장 후 목록 갱신 실패: ${errorToString(error)}`].filter(Boolean).join(' ') }) }
    } catch (error) {
      if (attempt.stage === 'sent') attempt.stage = 'answered'
      const sent = attempt.stage === 'answered'
      if (this.owns(authority, version)) {
        if (error instanceof RuntimeTomlRevisionConflict) {
          try {
            const current = sourceGeneration === runtimeTomlSourceGeneration.peek() ? error.current : null
            if (current) readMachineActivity(current.source_text, this.lane)
            this.update({ current, uncertain: null, error: current
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
      if (this.owns(authority, version)) { this.update({ phase: 'idle' }) }
    }
    if ((committed || this.state.peek().uncertain === attempt) && this.owns(authority, version)) {
      if (!committed) { announceRuntimeTomlWritten(); announceMachineLaneObservationChanged(authority) }
      await this.read(authority)
    }
    return committed && this.admits(authority)
  }
}

export function machineLaneActivitySessionFor(authority: ExecutionWorkspaceAuthority, lane: MachineActivityLane) {
  const key = JSON.stringify([authority.workspaceRoot, lane])
  let session = sessions.get(key)
  if (!session) { session = new MachineLaneActivitySession(authority.workspaceRoot, lane); sessions.set(key, session) }
  return session
}
effect(() => {
  const authority = executionWorkspaceAuthority.value, generation = runtimeTomlSourceGeneration.value
  for (const session of sessions.values()) session.invalidate(authority, generation)
})
export function resetMachineLaneActivitySessionsForTesting() { sessions.clear(); syncUnloadGuard() }
