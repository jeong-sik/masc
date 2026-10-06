import { effect, signal } from '@preact/signals'
import {
  fetchRuntimeDefaults, fetchRuntimeResolved, fetchRuntimeProviders, fetchRuntimeTomlConfig,
  type RuntimeDefaultsResponse, type RuntimeResolvedResponse, type DashboardRuntimeProvidersResponse,
  type RuntimeTomlConfig, type CommittedRuntimeTomlConfig,
} from '../api/dashboard'
import type { RuntimeTomlRequestOptions } from '../api/dashboard-runtime'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'
import { idle, loading, loaded, failed, type AsyncState } from './async-state'
import { announceRuntimeTomlWritten, announceRuntimeTomlWriteUncertain, runtimeTomlSourceGeneration } from './runtime-toml-source-generation'
import { resumeSavedModelSetup } from './model-setup-resume'
import { refreshRuntimeConfigConsumers } from './runtime-config-refresh'
import { runtimeConfigCommitReceiptNotice } from './runtime-config-receipt'
import { errorToString } from './format-string'
import { announceExactLaneObservationChanged } from './exact-lane-observation'

type Readings = {
  defaults: RuntimeDefaultsResponse; resolved: RuntimeResolvedResponse;
  providers: DashboardRuntimeProvidersResponse; source: RuntimeTomlConfig;
}
type WriteTarget = 'routing' | 'lane'
type WriteState = { phase: 'idle' } | {
  phase: 'saving' | 'saved' | 'error'; target: WriteTarget; message: string;
  receipt: CommittedRuntimeTomlConfig | null;
}
type State = { [K in keyof Readings]: AsyncState<Readings[K]> } & { write: WriteState; uncertain: { attempt: number } | null }
const stale = () => new Error('작업공간 또는 설정 조회가 바뀌었습니다.')
type Attachment = { controller: AbortController; observed: boolean; cancelUnsent: (() => void) | null }
const sessions = new WeakMap<ExecutionWorkspaceAuthority, SettingsRuntimeSession>()

/** The exact workspace authority owns writes and their uncertain outcomes across
 * navigation. Each attachment owns only its reads and unsent intent. Raw editor
 * drafts remain in their independent session. */
export class SettingsRuntimeSession {
  readonly state = signal<State>({ defaults: idle, resolved: idle, providers: idle, source: idle,
    write: { phase: 'idle' }, uncertain: null })
  private attachment: Attachment | null = null
  private readonly requests = { defaults: 0, resolved: 0, providers: 0, source: 0 }
  private sourceDemanded = false
  private writeAttempt = 0
  constructor(readonly authority: ExecutionWorkspaceAuthority) {}
  private ownsAuthority() { return executionWorkspaceAuthority.peek() === this.authority }
  private attached(attachment: Attachment | null): attachment is Attachment {
    return attachment !== null && this.attachment === attachment && !attachment.controller.signal.aborted && this.ownsAuthority()
  }
  current() { return this.attached(this.attachment) }
  attach(): () => void {
    this.attachment?.cancelUnsent?.()
    this.attachment?.controller.abort()
    const attachment: Attachment = { controller: new AbortController(), observed: false, cancelUnsent: null }
    this.attachment = attachment
    this.update({ defaults: idle, resolved: idle, providers: idle, source: idle })
    return () => {
      attachment.cancelUnsent?.()
      attachment.controller.abort()
      if (this.attachment === attachment) this.attachment = null
    }
  }
  private update(change: Partial<State>) {
    if (this.ownsAuthority()) this.state.value = { ...this.state.peek(), ...change }
  }
  private async read<K extends keyof Readings>(key: K, fetch: () => Promise<Readings[K]>): Promise<Readings[K]> {
    const attachment = this.attachment
    if (!this.attached(attachment)) throw stale()
    const request = ++this.requests[key], generation = runtimeTomlSourceGeneration.peek()
    const current = () => this.attached(attachment) && this.requests[key] === request && runtimeTomlSourceGeneration.peek() === generation
    this.update({ [key]: loading })
    try {
      const value = await fetch()
      if (!current()) throw stale()
      this.update({ [key]: loaded(value) })
      return value
    } catch (error) {
      if (current()) this.update({ [key]: failed(errorToString(error)) })
      throw error
    }
  }
  async readSource(): Promise<RuntimeTomlConfig> {
    const attachment = this.attachment
    this.sourceDemanded = true
    return this.read('source', async () => {
      const source = await fetchRuntimeTomlConfig({ beforeDispatch: () => { if (!this.attached(attachment)) throw stale() } })
      if (!source.ok || source.path === null) throw new Error('현재 runtime.toml 파일을 확인하지 못했습니다.')
      return source
    })
  }
  async refreshOnObservation(fileCommitted = false): Promise<void> {
    const attachment = this.attachment
    if (!this.attached(attachment)) return
    // Shared verified commits also refresh the source used by lane edits.
    if (fileCommitted) this.sourceDemanded = true
    // A new view reads even if it inherits a pending/uncertain write. Later
    // notifications cannot silently recover that outcome; explicit Read can.
    const initial = !attachment.observed
    const state = this.state.peek()
    if (initial || state.write.phase !== 'saving' && state.uncertain === null) await this.refresh()
  }
  async refresh(): Promise<void> {
    const attachment = this.attachment
    if (!this.attached(attachment)) return
    attachment.observed = true
    const recovering = this.state.peek().uncertain
    const options = { signal: attachment.controller.signal }
    // All readers settle independently: a failed catalog must not suppress the
    // resolved/file refresh or leave a rejected sibling promise unobserved.
    const results = await Promise.allSettled([
      this.read('defaults', () => fetchRuntimeDefaults(options)),
      this.read('resolved', () => fetchRuntimeResolved(options)),
      this.read('providers', () => fetchRuntimeProviders(options)),
      ...(this.sourceDemanded || this.state.peek().uncertain ? [this.readSource()] : []),
    ])
    if (!this.attached(attachment)) return
    const failure = results.find(result => result.status === 'rejected')
    if (failure?.status === 'rejected') throw failure.reason
    if (recovering !== null && this.state.peek().uncertain === recovering) this.update({ uncertain: null })
  }
  canWrite() {
    const state = this.state.peek()
    return this.current() && state.resolved.status === 'loaded' && state.write.phase !== 'saving' && !state.uncertain
  }
  async save(target: WriteTarget, label: string,
    send: (options: RuntimeTomlRequestOptions) => Promise<CommittedRuntimeTomlConfig>): Promise<boolean> {
    if (!this.canWrite()) return false
    const attachment = this.attachment
    if (!this.attached(attachment)) return false
    const attempt = ++this.writeAttempt
    const controller = new AbortController()
    // Leaving Settings cancels its reads and unsent intent. An already-sent
    // write still owns settlement/resume while the same workspace is current.
    const owns = () => this.writeAttempt === attempt && !controller.signal.aborted && this.ownsAuthority()
    let unwatch: (() => void) | null = effect(() => { if (executionWorkspaceAuthority.value !== this.authority) controller.abort() })
    const stopWatching = () => { unwatch?.(); unwatch = null }
    let dispatched = false, receipt: CommittedRuntimeTomlConfig | null = null
    const cancelUnsent = () => {
      if (dispatched || this.writeAttempt !== attempt) return
      controller.abort()
      stopWatching()
      attachment.cancelUnsent = null
      this.update({ write: { phase: 'error', target, receipt: null,
        message: '화면을 떠나 저장 요청을 전송하지 않았습니다.' } })
    }
    const options = { beforeDispatch: () => {
      if (!owns() || !this.attached(attachment)) throw stale()
      dispatched = true
      attachment.cancelUnsent = null
    } }
    attachment.cancelUnsent = cancelUnsent
    this.update({ write: { phase: 'saving', target, message: '', receipt: null } })
    try {
      receipt = await send(options)
      if (!owns()) return false
      // An acknowledged write is settled outside the attachment as well.
      attachment.cancelUnsent = null
      this.update({ source: loaded(receipt), write: { phase: 'saving', target,
        message: `저장됨 · ${runtimeConfigCommitReceiptNotice(receipt)}`, receipt } })
      announceRuntimeTomlWritten()
      const resumed = await resumeSavedModelSetup({ signal: controller.signal })
      if (!owns()) return false
      announceExactLaneObservationChanged(this.authority)
      const results = await Promise.allSettled([
        ...(this.current() ? [this.refresh()] : []), refreshRuntimeConfigConsumers(),
      ])
      if (!owns()) return false
      const failures = results.flatMap(result => result.status === 'rejected' ? [errorToString(result.reason)] : [])
      if (resumed.kind === 'failed') failures.unshift('런타임 재개를 확인하지 못했습니다.')
      this.update({ write: { phase: failures.length ? 'error' : 'saved', target, receipt,
        message: `${label} 저장됨 · ${runtimeConfigCommitReceiptNotice(receipt)}`
          + (failures.length ? ` · 대시보드 런타임 갱신 실패: ${failures.join(' ')}` : '') } })
      return true
    } catch (error) {
      if (owns()) {
        const uncertain = dispatched && receipt === null
        this.update({ uncertain: uncertain ? { attempt } : null,
          write: { phase: 'error', target, receipt, message: errorToString(error)
            + (uncertain ? ' 저장 결과가 불확실합니다. 현재 설정을 다시 읽으세요.' : '') } })
        if (uncertain) announceRuntimeTomlWriteUncertain()
      }
      return false
    } finally {
      stopWatching()
      if (attachment.cancelUnsent === cancelUnsent) attachment.cancelUnsent = null
    }
  }
}

export function settingsRuntimeSessionFor(authority: ExecutionWorkspaceAuthority): SettingsRuntimeSession {
  let session = sessions.get(authority)
  if (!session) { session = new SettingsRuntimeSession(authority); sessions.set(authority, session) }
  return session
}
