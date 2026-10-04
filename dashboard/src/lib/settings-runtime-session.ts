import { effect, signal } from '@preact/signals'
import {
  fetchRuntimeDefaults, fetchRuntimeResolved, fetchRuntimeProviders, fetchRuntimeTomlConfig,
  type RuntimeDefaultsResponse, type RuntimeResolvedResponse, type DashboardRuntimeProvidersResponse,
  type RuntimeTomlConfig, type CommittedRuntimeTomlConfig,
} from '../api/dashboard'
import type { RuntimeTomlRequestOptions } from '../api/dashboard-runtime'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'
import { idle, loading, loaded, failed, type AsyncState } from './async-state'
import { announceRuntimeTomlWritten, runtimeTomlSourceGeneration } from './runtime-toml-source-generation'
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

/** The mounted Settings surface owns these readings and typed writes. A new
 * authority gets a new session immediately, so retained A values cannot render
 * as B while effects are still cleaning up. Raw editor drafts have their own
 * longer-lived session and are never copied into this one. */
export class SettingsRuntimeSession {
  readonly state = signal<State>({ defaults: idle, resolved: idle, providers: idle, source: idle,
    write: { phase: 'idle' }, uncertain: null })
  private readonly controller = new AbortController()
  private readonly requests = { defaults: 0, resolved: 0, providers: 0, source: 0 }
  private sourceDemanded = false
  private writeAttempt = 0
  constructor(readonly authority: ExecutionWorkspaceAuthority) {}
  current() { return !this.controller.signal.aborted && executionWorkspaceAuthority.peek() === this.authority }
  dispose() { this.controller.abort() }
  private update(change: Partial<State>) {
    if (this.current()) this.state.value = { ...this.state.peek(), ...change }
  }
  private async read<K extends keyof Readings>(key: K, fetch: () => Promise<Readings[K]>): Promise<Readings[K]> {
    if (!this.current()) throw stale()
    const request = ++this.requests[key], generation = runtimeTomlSourceGeneration.peek()
    const current = () => this.current() && this.requests[key] === request && runtimeTomlSourceGeneration.peek() === generation
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
    this.sourceDemanded = true
    return this.read('source', async () => {
      const source = await fetchRuntimeTomlConfig({ beforeDispatch: () => { if (!this.current()) throw stale() } })
      if (!source.ok || source.path === null) throw new Error('현재 runtime.toml 파일을 확인하지 못했습니다.')
      return source
    })
  }
  async refresh(): Promise<void> {
    if (!this.current()) return
    const recovering = this.state.peek().uncertain
    const options = { signal: this.controller.signal }
    // All readers settle independently: a failed catalog must not suppress the
    // resolved/file refresh or leave a rejected sibling promise unobserved.
    const results = await Promise.allSettled([
      this.read('defaults', () => fetchRuntimeDefaults(options)),
      this.read('resolved', () => fetchRuntimeResolved(options)),
      this.read('providers', () => fetchRuntimeProviders(options)),
      ...(this.sourceDemanded || this.state.peek().uncertain ? [this.readSource()] : []),
    ])
    if (!this.current()) return
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
    const attempt = ++this.writeAttempt
    const controller = new AbortController()
    // Leaving Settings cancels its reads and unsent intent. An already-sent
    // write still owns settlement/resume while the same workspace is current.
    const owns = () => !controller.signal.aborted && executionWorkspaceAuthority.peek() === this.authority
    const unwatch = effect(() => { if (executionWorkspaceAuthority.value !== this.authority) controller.abort() })
    let dispatched = false, receipt: CommittedRuntimeTomlConfig | null = null
    const options = { beforeDispatch: () => {
      if (!this.current()) throw stale()
      dispatched = true
    } }
    this.update({ write: { phase: 'saving', target, message: '', receipt: null } })
    try {
      receipt = await send(options)
      if (!owns()) return false
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
      if (this.current()) this.update({ uncertain: dispatched && receipt === null ? { attempt } : null,
        write: { phase: 'error', target, receipt, message: errorToString(error)
          + (dispatched && receipt === null ? ' 저장 결과가 불확실합니다. 현재 설정을 다시 읽으세요.' : '') } })
      return false
    } finally { unwatch() }
  }
}
