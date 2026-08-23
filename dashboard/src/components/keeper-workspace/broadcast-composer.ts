// Keeper Workspace — 전체 브로드캐스트 작성기 (rails.jsx BroadcastComposer).
// `masc_broadcast`는 content 만 받는다 — 수신 범위(scope)와 경로(via) 선택은
// 백엔드가 지원하지 않으므로 디자인의 `.bcc-seg`/`.bcc-opt` 선택 UI는 심지
// 않았다 (선택해도 delivery에 반영되지 않는 fake 가 된다). 수신자 칩 목록은
// 실제 broadcast 가 닿는 워크스페이스 keeper 전원 = live `keepers` store.
// 전송은 기존 board composer 와 같은 sendBroadcast + receipt 처리 경로를 쓴다.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import type { Keeper } from '../../types'
import { broadcastReceiptMessage, currentDashboardActor, sendBroadcast } from '../../api'
import { showToast } from '../common/toast'
import { errorToString } from '../../lib/format-string'
import { WorkspaceSigil } from './keeper-workspace-shared'

export function BroadcastComposer({
  keepers,
  onClose,
}: {
  keepers: readonly Keeper[]
  onClose: () => void
}): VNode {
  const [msg, setMsg] = useState('')
  const [sending, setSending] = useState(false)

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.stopPropagation()
        onClose()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
    // onClose is stable per mount in practice; re-binding on identity change is cheap.
  }, [onClose])

  const recipients = keepers
  const canSend = msg.trim().length > 0 && recipients.length > 0 && !sending

  const send = () => {
    if (!canSend) return
    setSending(true)
    void (async () => {
      try {
        const receipt = await sendBroadcast(currentDashboardActor(), msg.trim())
        if (!receipt.ok) {
          // Persisted-but-not-delivered and outcome_unknown both must NOT be
          // retried blindly — the receipt message says so (do not resend).
          showToast(broadcastReceiptMessage(receipt), 'warning', 8000)
          return
        }
        showToast(`${recipients.length} keeper에게 브로드캐스트`, 'success')
        onClose()
      } catch (err) {
        showToast(`브로드캐스트 실패: ${errorToString(err)}`, 'error', 8000)
      } finally {
        setSending(false)
      }
    })()
  }

  return html`
    <div class="turn-overlay" onClick=${onClose}>
      <div
        class="turn-drawer bcc-drawer"
        role="dialog"
        aria-modal="true"
        aria-label="전체 브로드캐스트"
        onClick=${(event: MouseEvent) => event.stopPropagation()}
      >
        <div class="turn-hd">
          <h3>전체 브로드캐스트</h3>
          <span class="tid mono">masc_broadcast</span>
          <span style=${{ marginLeft: 'auto' }}></span>
          <button type="button" class="turn-close" onClick=${onClose} title="닫기 (Esc)">${'✕'}</button>
        </div>
        <div class="turn-body">
          <div class="turn-sec">
            <h4>수신 범위</h4>
            <div class="bcc-recips">
              ${recipients.length === 0
                ? html`<span class="bcc-empty mono">대상 keeper 없음</span>`
                : recipients.map(k => html`
                    <span class="bcc-chip" key=${k.name}>
                      <${WorkspaceSigil} id=${k.name} size=${16} />
                      <span class="mono">${k.name}</span>
                    </span>
                  `)}
            </div>
          </div>
          <div class="turn-sec">
            <h4>메시지 · 모든 대상에게 동일</h4>
            <textarea
              class="bcc-text"
              placeholder="모든 대상 keeper에게 전달할 동일 메시지…"
              value=${msg}
              rows=${4}
              autoFocus
              onInput=${(event: Event) => setMsg((event.target as HTMLTextAreaElement).value)}
            ></textarea>
            <div class="bcc-hint mono">masc_broadcast는 워크스페이스 전체에 게시됩니다 · 대상/경로 선택은 백엔드 미지원</div>
          </div>
          <div class="turn-sec bcc-actions">
            <button
              type="button"
              class="bcc-send"
              disabled=${!canSend}
              onClick=${send}
            >${sending ? '보내는 중…' : `⊚ ${recipients.length}명에게 보내기`}</button>
            <button type="button" class="sch-act ghost" onClick=${onClose}>취소</button>
          </div>
        </div>
      </div>
    </div>
  `
}
