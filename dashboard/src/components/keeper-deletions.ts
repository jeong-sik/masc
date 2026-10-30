import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { ActionButton } from './common/button'
import { keeperDeletionInventory, keeperDeletionError, refreshKeeperDeletions } from '../store'
import { retryKeeperDeletion, type KeeperPurgeStatus } from '../api/keeper-lifecycle'
import { showToast } from './common/toast'

// Independent of roster membership: cleanup can outlive metadata removal.
export function KeeperDeletions() {
  const busy = useSignal(false)
  const retry = async (operation: KeeperPurgeStatus) => {
    if (busy.value) return
    busy.value = true
    try {
      await retryKeeperDeletion(operation.keeperName, operation.operationId, operation.kind)
      showToast(`${operation.keeperName}: 정리 재시도 접수됨`, 'success')
    } catch (error) {
      showToast(error instanceof Error ? error.message : '정리 재시도 실패', 'error')
    } finally {
      await refreshKeeperDeletions()
      busy.value = false
    }
  }
  const refresh = async () => {
    if (busy.value) return
    busy.value = true
    try { await refreshKeeperDeletions() } finally { busy.value = false }
  }
  useEffect(() => { void refresh() }, [])
  const inventory = keeperDeletionInventory.value
  const error = keeperDeletionError.value
  return html`
    <details class="p-3" data-testid="keeper-deletions">
      <summary>키퍼 삭제 기록${inventory ? ` · ${inventory.operations.length}건` : ''}</summary>
      <p>키퍼가 목록에서 사라져도 종료·파일 정리 결과는 이 기록에서 확인합니다.</p>
      <${ActionButton} variant="ghost" disabled=${busy.value} onClick=${refresh}>${busy.value ? '조회 중' : '상태 새로고침'}<//>
      ${error ? html`<p role="alert">${error} · 표시된 기록은 최신 상태가 아닐 수 있습니다.</p>` : null}
      ${!inventory && !error ? html`<p>삭제 기록을 불러오는 중입니다.</p>` : null}
      ${inventory?.configurationErrors.map(error => html`<p role="alert">설정 삭제 기록 조회 실패: ${error}</p>`)}
      ${inventory?.errors.map(row => html`<p role="alert" key=${row.operationId}>
        ${row.keeperName} · ${row.operationId}: 종료 기록을 해석할 수 없습니다. ${row.error}
      </p>`)}
      ${inventory?.operations.map(row => html`<article class="py-2 border-b" key=${row.operationId}>
        <strong>${row.keeperName}</strong> · <span>${row.description}</span>
        <div><code>${row.operationId}</code></div>
        ${row.source ? html`<div>${row.source.path}<br /><code>${row.source.sha256}</code></div>` : null}
        ${row.canRetry ? html`<${ActionButton} variant="ghost" disabled=${busy.value}
          onClick=${() => retry(row)}>남은 정리 재시도<//>` : null}
      </article>`)}
      ${inventory && !inventory.operations.length && !inventory.errors.length && !inventory.configurationErrors.length
        ? html`<p>저장된 키퍼 삭제 기록이 없습니다.</p>` : null}
    </details>
  `
}
