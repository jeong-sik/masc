// Connector action failures — headline toast, raw detail on demand.
//
// The server's error text for sidecar/bind actions carries operator
// internals (filesystem paths it probed, env-var hints — e.g. the
// 2026-06-11 sidecar-stop error listed two absolute paths and a
// MASC_SIDECAR_ROOT instruction). Dumping that into a toast buries the
// one thing the operator needs first: which action on which connector
// failed. The headline comes from the call site's typed context — no
// string classification of the server text — and the raw text stays
// one click away, copyable for a report.

import { showActionToast, showToast } from './common/toast'
import { requestConfirm } from './common/confirm-dialog'

export function rawErrorText(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

/** Error toast for a connector action: [headline] + '상세' button that
    opens the full server text in a dialog. */
export function showConnectorActionError(headline: string, err: unknown): void {
  const raw = rawErrorText(err)
  showActionToast(
    headline,
    { label: '상세', onClick: () => { void openConnectorErrorDetail(headline, raw) } },
    'error',
  )
}

/** requestConfirm doubles as the read-only detail dialog. Copy must
    sit on the CONFIRM slot: ConfirmDialogOverlay maps Escape and
    backdrop-click to onCancel, so anything on the cancel slot also
    fires on accidental dismissal. Confirm only fires on a deliberate
    button click — cancel/Escape/backdrop are all a plain close. */
export async function openConnectorErrorDetail(headline: string, raw: string): Promise<void> {
  const copyRequested = await requestConfirm({
    title: headline,
    message: raw,
    confirmText: '복사 후 닫기',
    cancelText: '닫기',
    tone: 'info',
  })
  if (copyRequested) {
    try {
      await navigator.clipboard.writeText(raw)
      showToast('오류 내용을 클립보드에 복사했습니다.', 'success')
    } catch {
      showToast('클립보드 복사 실패 — 본문을 직접 선택해 복사하세요.', 'warning')
    }
  }
}
