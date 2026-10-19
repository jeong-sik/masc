import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { Schema } from 'effect'
import { ArtifactPublicationSchema, artifactHref } from '../../api/published-artifacts'
import { toolCallCompletion, type ToolCallEntry } from '../../api/dashboard-keeper-tool-calls'
import { fetchVerifiedToolBlobText } from '../../api/verified-tool-blob'
import { currentStoredTokenRevision } from '../../api/core'
import { storedTokenRevision } from '../../api/token-revision'

type Publication = typeof ArtifactPublicationSchema.Type

function decodePublication(text: string, manifest: boolean): Publication {
  const json: unknown = JSON.parse(text)
  if (manifest) {
    const envelope = Schema.decodeUnknownSync(Schema.Struct({
      schema: Schema.Literal('masc.tool-result-artifact-manifest.v1'), structured_content: Schema.Unknown,
    }))(json)
    return Schema.decodeUnknownSync(ArtifactPublicationSchema)(envelope.structured_content)
  }
  return Schema.decodeUnknownSync(ArtifactPublicationSchema)(json)
}

// The caller supplies output from the exact execution-id endpoint. Neither
// model prose nor a partial trace result can establish a published document.
export function PublishedArtifactCard({ output }: { output: ToolCallEntry | null }) {
  const authRevision = storedTokenRevision.value
  const eligible = output !== null && toolCallCompletion(output) === true
    && output.route_evidence?.descriptor_id === 'keeper.artifact.publish'
  const blob = eligible && output && typeof output.output === 'object' ? output.output._blob : null
  const key = JSON.stringify([authRevision, output?.execution_id, blob?.sha256, blob?.bytes])
  const [result, setResult] = useState<{ key: string; value: Publication | null } | null>(null)
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    if (!blob || !eligible) return
    const controller = new AbortController()
    void fetchVerifiedToolBlobText(blob, controller.signal)
      .then(text => decodePublication(text, blob.mime === 'application/vnd.masc.tool-result-manifest+json'))
      .then(value => {
        if (!controller.signal.aborted && currentStoredTokenRevision() === authRevision) setResult({ key, value })
      }, () => {
        if (!controller.signal.aborted && currentStoredTokenRevision() === authRevision) setResult({ key, value: null })
      })
    return () => controller.abort()
  }, [eligible, blob?.sha256, blob?.bytes, blob?.mime, key, authRevision, attempt])
  if (!eligible || !output) return null
  let publication: Publication | null = null
  if (blob) {
    if (result?.key !== key) return html`<p role="status" class="m-2 text-xs">게시된 문서 링크를 불러오고 있습니다.</p>`
    publication = result.value
  } else {
    try { publication = decodePublication(output.output as string, false) } catch { /* exact receipt may be unavailable */ }
  }
  if (!publication) return html`<div role="alert" class="m-2 text-xs">게시 결과에서 문서 링크를 읽지 못했습니다.
    ${blob ? html`<button type="button" onClick=${() => { setResult(null); setAttempt(n => n + 1) }}>다시 조회</button>` : null}</div>`
  const artifact = publication.artifact
  return html`
    <a href=${artifactHref(artifact.id, artifact.revision)}
      class="m-2 block rounded-lg border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3 hover:bg-[var(--color-bg-hover)]"
      aria-label=${`아티팩트 열기: ${artifact.title}`}>
      <span class="block text-xs text-[var(--color-fg-muted)]">아티팩트 · ${artifact.format} · v${artifact.revision}</span>
      <strong class="mt-1 block break-words">${artifact.title}</strong>
      <span class="mt-1 block text-sm text-[var(--color-fg-secondary)]">${artifact.summary}</span>
      <span class="mt-2 block text-xs">문서 열기 →</span>
    </a>
  `
}
