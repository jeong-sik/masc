import { signal } from '@preact/signals'
import { currentStoredTokenRevision } from '../api/core'
import { restorePromptPreset, savePromptPreset, type PromptPresetManifest, type PromptPresetReport, type PromptPresetWrite } from '../api/prompt-presets'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'

export type PromptPresetOwner = { authority: ExecutionWorkspaceAuthority; credentialRevision: number }
export const ownsPromptPresetRequest = (owner: PromptPresetOwner) =>
  executionWorkspaceAuthority.peek() === owner.authority && currentStoredTokenRevision() === owner.credentialRevision

export type PromptPresetOperation = { owner: PromptPresetOwner; name: string } & (
  | { action: 'save'; result: { kind: 'pending' } | PromptPresetWrite<PromptPresetManifest> }
  | { action: 'restore'; result: { kind: 'pending' } | PromptPresetWrite<PromptPresetReport> })
const sessions = new Map<string, PromptPresetSession>()

/** A workspace owns the sent operation across navigation and reconnection.
 * Reads and confirmation remain attached to an exact authority object. */
export class PromptPresetSession {
  readonly state = signal<{ operation: PromptPresetOperation | null; needsRead: boolean; uncertainty: number }>({
    operation: null, needsRead: false, uncertainty: 0,
  })
  constructor(readonly workspaceRoot: string) {}
  reconcile(owner: PromptPresetOwner, uncertainty: number) {
    const state = this.state.peek()
    if (ownsPromptPresetRequest(owner) && state.uncertainty === uncertainty && state.operation?.result.kind !== 'pending') {
      this.state.value = { ...state, needsRead: false }
    }
  }
  async write(owner: PromptPresetOwner, action: 'save' | 'restore', name: string, description: string) {
    const state = this.state.peek()
    if (!ownsPromptPresetRequest(owner) || owner.authority.workspaceRoot !== this.workspaceRoot
      || state.needsRead || state.operation?.result.kind === 'pending') return null
    const operation: PromptPresetOperation = { owner, action, name, result: { kind: 'pending' } }
    this.state.value = { ...state, operation }
    const beforeDispatch = () => {
      if (!ownsPromptPresetRequest(owner)) throw new Error('작업공간 또는 인증이 바뀌어 요청을 보내지 않았습니다.')
    }
    const settled: PromptPresetOperation = action === 'save'
      ? { owner, action, name, result: await savePromptPreset(name, description, { beforeDispatch }) }
      : { owner, action, name, result: await restorePromptPreset(name, { beforeDispatch }) }
    // Settlement belongs to the original request even when its view or
    // authority has gone. A new authority cannot apply its read side effects.
    const current = this.state.peek()
    const recheck = settled.result.kind === 'unconfirmed'
      || settled.result.kind === 'confirmed' && !ownsPromptPresetRequest(owner)
    this.state.value = { operation: settled,
      needsRead: current.needsRead || recheck,
      uncertainty: current.uncertainty + (recheck ? 1 : 0) }
    return settled
  }
}

export function promptPresetSessionFor(authority: ExecutionWorkspaceAuthority): PromptPresetSession {
  let session = sessions.get(authority.workspaceRoot)
  if (!session) { session = new PromptPresetSession(authority.workspaceRoot); sessions.set(authority.workspaceRoot, session) }
  return session
}
export function resetPromptPresetSessionsForTesting() { sessions.clear() }
