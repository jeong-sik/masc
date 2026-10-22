import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { currentStoredTokenRevision } from '../../api/core'
import { setArtifactCheck, type ArtifactCheckState } from '../../api/published-artifact-checks'
import type { PublishedArtifact } from '../../api/published-artifacts'

export function ArtifactCheckControl({ artifact, state, authRevision, onChanged }: {
  artifact: PublishedArtifact; state: ArtifactCheckState; authRevision: number; onChanged: () => void
}) {
  const owner = useRef({ active: true })
  const [pending, setPending] = useState(false)
  const [message, setMessage] = useState('')
  useEffect(() => () => { owner.current.active = false }, [])

  const toggle = async () => {
    if (pending || state.kind !== 'known') return
    setPending(true)
    setMessage('')
    try {
      await setArtifactCheck(artifact, state.check, !state.check?.checked)
      if (!owner.current.active || currentStoredTokenRevision() !== authRevision) return
      setMessage('저장했습니다. 공유 확인 상태를 다시 조회합니다.')
    } catch (error) {
      if (!owner.current.active || currentStoredTokenRevision() !== authRevision) return
      setMessage(`${error instanceof Error ? error.message : '확인 상태를 저장하지 못했습니다.'} 다시 조회한 상태에서 확인해 주세요.`)
    }
    if (!owner.current.active || currentStoredTokenRevision() !== authRevision) return
    // Even a timeout or conflict may follow an applied change. Never retry or
    // optimistically mark it checked: request an authoritative shared reread.
    setPending(false)
    onChanged()
  }

  const checked = state.kind === 'known' && state.check?.checked === true
  return html`<div class="flex flex-wrap items-center gap-2 text-xs" aria-label=${`${artifact.title} v${artifact.revision} 확인 상태`}>
    <button type="button" disabled=${pending || state.kind !== 'known'} aria-pressed=${checked}
      onClick=${toggle}>${pending ? '확인 상태 저장 중…' : state.kind === 'unknown' ? '확인 상태 알 수 없음' : checked ? '✓ 확인함' : '○ 미확인'}</button>
    <span class="text-[var(--color-fg-muted)]">${state.kind === 'unknown' ? state.message
      : state.check ? `${state.check.checked ? '확인' : '확인 해제'} · ${state.check.changed_by} · ${new Date(state.check.changed_at).toLocaleString()}` : `v${artifact.revision} 확인 기록 없음`}</span>
    ${message ? html`<span aria-live="polite">${message}</span>` : null}
  </div>`
}
