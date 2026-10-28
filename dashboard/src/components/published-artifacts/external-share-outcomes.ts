import { html } from 'htm/preact'
import { artifactExternalSharing } from '../../lib/artifact-external-sharing'

export function ExternalShareOutcomes() {
  const outcomes = artifactExternalSharing.receipts()
  if (!outcomes.length) return null
  return html`<section aria-label="외부 공유 요청 결과" aria-live="polite" class="max-h-24 overflow-auto text-xs">
    ${[...outcomes].reverse().map((outcome, index) => html`<p key=${index}>
      ${outcome.title} · ${outcome.id} · v${outcome.revision}
      · 원래 작업 공간 ${outcome.workspace.basePath} (${outcome.workspace.mascRoot})
      · 요청: ${outcome.requested ? '외부 공유 켜기' : '외부 공유 해제'}
      · ${outcome.kind === 'confirmed'
        ? `서버 응답: ${outcome.shared ? '공유 켜짐' : '공유 해제됨'}`
        : `적용 여부 미확인: ${outcome.detail}`}
    </p>`)}
  </section>`
}
