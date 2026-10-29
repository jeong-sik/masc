import { html } from 'htm/preact'
import { artifactPublicationOutcomes, type ArtifactPublicationOwner } from '../../lib/artifact-publication-outcomes'

export function PublicationOutcomes({ currentOwner }: { currentOwner?: ArtifactPublicationOwner }) {
  const publications = artifactPublicationOutcomes.records()
  if (!publications.length) return null
  return html`<section aria-label="문서 저장 요청 결과" aria-live="polite" class="max-h-24 overflow-auto text-xs">
    ${publications.map(({ owner: original, outcome }, index) => html`<p key=${index}>
      ${outcome.title} · 원래 작업 공간 ${outcome.workspace.basePath} (${outcome.workspace.mascRoot})
      ${outcome.kind === 'published' ? html` · ${outcome.publication.artifact.id} · v${outcome.publication.artifact.revision}
        · ${outcome.verified ? '저장 내용 확인됨' : '저장 응답 받음 · 내용 확인 필요'}`
        : outcome.kind === 'checkpoint' ? html` · 공동 원고 기준을 v${outcome.publication.artifact.revision}으로 갱신 요청 · ${
          outcome.status === 'pending' ? '갱신 중' : outcome.status === 'checkpointed' ? '당시 갱신됨 (이후 변경될 수 있음)'
            : outcome.status === 'already_current' ? '당시 이미 갱신됨 (이후 변경될 수 있음)' : outcome.status === 'refused'
              ? `갱신 거절됨: ${outcome.detail ?? ''}` : `갱신 결과 미확인: ${outcome.detail ?? ''}`}`
        : ` · 적용 여부 미확인: ${outcome.detail}`}
      ${original !== currentOwner ? ' · 이전 접근 상태의 요청 결과' : ''}
    </p>`)}
  </section>`
}
