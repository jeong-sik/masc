import { html } from 'htm/preact'
import { currentStoredTokenRevision, getStoredToken } from '../../api/core'
import { captureArtifactWorkspace, setPublishedArtifactShared } from '../../api/published-artifacts'
import { artifactExternalSharing } from '../../lib/artifact-external-sharing'
import { forgetPendingShare, pendingShares, type PendingShare } from '../../lib/artifact-share-recovery'
import { executionWorkspaceAuthority } from '../../store'

async function recover(record: PendingShare): Promise<void> {
  const { operation, workspace, title, revision } = record
  const owner = artifactExternalSharing.beginRecovery(operation.id)
  if (!owner) return
  const receipt = { id: operation.id, title, revision, requested: operation.shared, workspace }
  const authRevision = currentStoredTokenRevision()
  const authority = executionWorkspaceAuthority.peek()
  const current = () => authority !== null && authority.workspaceRoot === workspace.basePath
    && executionWorkspaceAuthority.peek() === authority && currentStoredTokenRevision() === authRevision
  try {
    if (!current()) throw new Error('원래 작업 공간의 현재 권한을 확인해 주세요.')
    const currentWorkspace = await captureArtifactWorkspace(workspace.basePath)
    if (currentWorkspace.mascRoot !== workspace.mascRoot || !current()) {
      throw new Error('작업 공간 또는 인증이 달라졌습니다.')
    }
    const result = await setPublishedArtifactShared(operation, workspace)
    if (!current()) throw new Error('접근 상태가 달라져 결과를 보관했습니다.')
    forgetPendingShare(record)
    artifactExternalSharing.finish(operation.id, owner, { ...receipt, kind: 'confirmed',
      outcome: result.receipt.outcome, shared: result.receipt.snapshot.shared, current: result.current.shared })
  } catch (error) {
    artifactExternalSharing.finish(operation.id, owner, { ...receipt, kind: 'unconfirmed',
      detail: error instanceof Error ? error.message : '요청 결과를 확인하지 못했습니다.' })
  }
}

export function ExternalShareOutcomes() {
  const authority = executionWorkspaceAuthority.value
  if (!authority || !getStoredToken()) return null
  const outcomes = artifactExternalSharing.receipts().filter(outcome => outcome.workspace.basePath === authority.workspaceRoot)
  const pending = pendingShares().filter(record => record.workspace.basePath === authority.workspaceRoot)
  if (!outcomes.length && !pending.length) return null
  return html`<section aria-label="외부 공유 요청 결과" aria-live="polite" class="max-h-24 overflow-auto text-xs">
    ${pending.map(record => html`<p key=${record.operation.operationId}>
      ${record.title} · ${record.operation.id} · 원래 작업 공간 ${record.workspace.basePath}
      · 요청 결과 미확인
      <button type="button" disabled=${artifactExternalSharing.activity(record.operation.id) === 'pending'}
        onClick=${() => void recover(record)}>같은 요청 확인</button>
      <span>확인 중 원래 요청이 적용될 수 있습니다.</span>
    </p>`)}
    ${[...outcomes].reverse().map((outcome, index) => html`<p key=${index}>
      ${outcome.title} · ${outcome.id} · v${outcome.revision}
      · 원래 작업 공간 ${outcome.workspace.basePath} (${outcome.workspace.mascRoot})
      · 요청: ${outcome.requested ? '외부 공유 켜기' : '외부 공유 해제'}
      · ${outcome.kind === 'confirmed'
        ? `${outcome.outcome === 'applied' ? '요청 적용' : '요청 충돌'}: 당시 ${outcome.shared ? '공유 켜짐' : '공유 해제됨'}, 현재 확인 ${outcome.current ? '공유 켜짐' : '공유 해제됨'}`
        : `적용 여부 미확인: ${outcome.detail}`}
    </p>`)}
  </section>`
}
