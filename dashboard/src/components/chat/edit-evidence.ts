import { useEffect, useState } from 'preact/hooks'
import { fetchVerifiedToolBlobText } from '../../api/verified-tool-blob'
import { html } from 'htm/preact'
import type { ToolCallEntry } from '../../api/dashboard'
import { parseEditSnapshots } from '../../api/edit-snapshots'
import { EditSnapshotView } from './edit-snapshot-view'

function object(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown> : null
}

type ManifestState = { key: string; kind: 'loading' }
  | { key: string; kind: 'loaded'; result: Record<string, unknown> }
  | { key: string; kind: 'failed'; message: string }

function decodedEditResult(text: string, manifest: boolean): Record<string, unknown> {
  const json: unknown = JSON.parse(text)
  if (!manifest) {
    const result = object(json)
    if (!result) throw new Error('저장된 편집 결과의 형식을 확인할 수 없습니다.')
    return result
  }
  const envelope = object(json)
  const structured = object(envelope?.structured_content)
  if (envelope?.schema !== 'masc.tool-result-artifact-manifest.v1'
      || typeof envelope.content !== 'string' || !structured) {
    throw new Error('저장된 편집 결과의 manifest 형식을 확인할 수 없습니다.')
  }
  return structured
}

// Read only a joined, successful Edit receipt. Provider display names and
// transcript arguments cannot identify an applied filesystem operation.
export function ChatEditEvidence({ output }: { output: ToolCallEntry | null }) {
  const eligible = output?.success === true && output.route_evidence?.descriptor_id === 'agent.edit_file'
  const blob = eligible && typeof output?.output === 'object' ? output.output._blob : null
  const key = blob ? JSON.stringify([blob.sha256, blob.bytes, blob.mime]) : null
  const [manifest, setManifest] = useState<ManifestState | null>(null)
  const [attempt, retry] = useState(0)
  useEffect(() => {
    if (!blob || !key) return
    const controller = new AbortController()
    setManifest({ key, kind: 'loading' })
    void fetchVerifiedToolBlobText(blob, controller.signal).then(text =>
      decodedEditResult(text, blob.mime === 'application/vnd.masc.tool-result-manifest+json'),
    ).then(result => {
      if (!controller.signal.aborted) setManifest({ key, kind: 'loaded', result })
    }, error => {
      if (!controller.signal.aborted) setManifest({ key, kind: 'failed',
        message: error instanceof Error ? error.message : '저장된 편집 결과를 불러오지 못했습니다.' })
    })
    return () => controller.abort()
  }, [key, attempt])
  if (!eligible || !output) return null
  const input = object(output.input)
  let result: Record<string, unknown> | null
  if (blob) {
    if (manifest?.key !== key || manifest.kind === 'loading') {
      return html`<p role="status" class="m-2 text-xs">저장된 편집 결과를 확인하고 있습니다.</p>`
    }
    if (manifest.kind === 'failed') return html`<div role="alert" class="m-2 text-xs">${manifest.message}
      <button type="button" class="ml-2 underline" onClick=${() => retry(value => value + 1)}>편집 결과 다시 조회</button>
    </div>`
    result = manifest.result
  } else {
    try { result = decodedEditResult(output.output as string, false) } catch { return null }
  }
  if (!result || result.ok !== true || result.mode !== 'patch'
      || typeof result.path !== 'string' || typeof result.occurrences !== 'number'
      || !Number.isSafeInteger(result.occurrences) || result.occurrences <= 0) return null
  const snapshots = parseEditSnapshots(result.edit_snapshots)
  const snippets = input && typeof input.old_string === 'string' && typeof input.new_string === 'string'
  if (!snapshots && !snippets) return null
  return html`
    <section class="m-2 rounded-md border border-border p-2" aria-label="편집 변경 기록" data-chat-edit-evidence>
      <div class="break-all text-xs font-mono">${result.path} · ${result.occurrences}곳 편집</div>
      ${snapshots?.status === 'stored' ? html`<${EditSnapshotView} key=${snapshots.before.sha256 + snapshots.after.sha256} refs=${snapshots} />` : null}
      ${snapshots?.status === 'unavailable' ? html`<p role="status" class="my-1 text-xs text-[var(--color-status-err)]">편집은 적용됐지만 원본 저장에 실패해 실제 파일 diff를 표시할 수 없습니다. ${snapshots.detail}</p>` : null}
      ${snippets ? html`<p class="my-1 text-xs text-[var(--color-fg-muted)]">성공한 편집 호출의 입력 기록입니다. 비밀값 마스킹·길이 제한·앞뒤 공백 제거로 일부 내용이 생략될 수 있어 실제 파일 diff와 다를 수 있습니다.</p>
      <div class="grid gap-2 md:grid-cols-2">
        <div><div class="text-xs text-[var(--color-status-err)]">기록된 찾기 입력</div>
          <pre tabIndex=${0} aria-label="기록된 찾기 입력 조각" class="max-h-64 overflow-auto whitespace-pre-wrap break-words text-xs focus-visible:ring-2 focus-visible:ring-ring">${input?.old_string}</pre>
        </div>
        <div><div class="text-xs text-[var(--color-ok-fg)]">기록된 바꾸기 입력</div>
          <pre tabIndex=${0} aria-label="기록된 바꾸기 입력 조각" class="max-h-64 overflow-auto whitespace-pre-wrap break-words text-xs focus-visible:ring-2 focus-visible:ring-ring">${input?.new_string}</pre>
        </div>
      </div>` : null}
    </section>
  `
}
