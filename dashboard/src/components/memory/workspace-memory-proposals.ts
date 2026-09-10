import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchWorkspaceMemoryProposals, type WorkspaceMemoryProposal, type WorkspaceMemoryProposals } from '../../api/workspace-memory-proposals'

type State = { kind: 'loading' } | { kind: 'error'; message: string }
  | { kind: 'ready'; value: WorkspaceMemoryProposals }

function Proposal({ value }: { value: WorkspaceMemoryProposal }) {
  const [evidence, setEvidence] = useState<string | null>(null)
  const sources = new Map(value.sources.map(row => [row.source_id, row]))
  const snapshots = new Map(value.snapshots.map(row => [row.snapshot_id, row]))
  const selected = evidence ? sources.get(evidence) : undefined
  const attribution = (id: string) => {
    const source = sources.get(id)
    const snapshot = source ? snapshots.get(source.snapshot_id) : undefined
    return `${id} · ${snapshot?.keeper_id} · ${snapshot?.store === 'ordinary' ? '일반 기억' : '파일 출처 기억'}`
  }
  const refs = (ids: string[]) => html`<div class="flex flex-wrap gap-2">${ids.map(id => html`
    <button type="button" class="underline break-all" onClick=${() => setEvidence(id)} aria-pressed=${evidence === id}>${attribution(id)}</button>`)}</div>`
  return html`<div class="grid min-w-0 gap-3">
    <section><h3>공유 기억 제안 · ${value.proposal.shared_claims.length}개</h3>
      ${value.proposal.shared_claims.map(row => html`<article class="border-t border-border py-2"><p class="whitespace-pre-wrap break-words">${row.claim}</p>${refs(row.source_ids)}</article>`)}
    </section>
    <section><h3>해결되지 않은 충돌 · ${value.proposal.conflicts.length}개</h3>
      ${value.proposal.conflicts.map(row => html`<article class="border-t border-border py-2"><p class="whitespace-pre-wrap break-words">${row.description}</p>${refs(row.source_ids)}</article>`)}
    </section>
    ${selected ? html`<section aria-label="선택한 출처" class="min-w-0 border border-border p-3">
      <h3>${attribution(selected.source_id)}</h3>
      <p>저장 당시의 출처입니다. 현재 파일 내용과 주장의 사실 여부는 재검증하지 않았습니다.</p>
      <pre tabIndex=${0} class="max-h-96 overflow-auto whitespace-pre-wrap break-words text-xs">${JSON.stringify({ source: selected, snapshot: snapshots.get(selected.snapshot_id) }, null, 2)}</pre>
      <button type="button" onClick=${() => setEvidence(null)}>출처 닫기</button>
    </section>` : null}
    <details><summary>제외한 출처 · ${value.proposal.excluded.length}개</summary>
      ${value.proposal.excluded.map(row => html`<article><p class="whitespace-pre-wrap break-words">${row.reason}</p>${refs([row.source_id])}</article>`)}
    </details>
    <section><h3>수집하지 못한 기억 · ${value.gaps.length}개</h3>
      ${value.gaps.map(row => html`<p class="break-words">${row.keeper_id} · ${row.store === 'ordinary' ? '일반 기억' : '파일 출처 기억'}: ${row.observation.status === 'missing' ? '저장된 기억 없음' : `읽기 실패: ${row.observation.detail}`}</p>`)}
    </section>
    <details><summary>제안과 출처 전체 원문</summary><pre tabIndex=${0} class="max-h-96 overflow-auto whitespace-pre-wrap break-words text-xs">${JSON.stringify(value, null, 2)}</pre></details>
  </div>`
}

export function WorkspaceMemoryProposalsPanel() {
  const [generation, setGeneration] = useState(0)
  const [state, setState] = useState<State>({ kind: 'loading' })
  const [selection, setSelection] = useState('')
  useEffect(() => {
    const controller = new AbortController()
    setState({ kind: 'loading' })
    void fetchWorkspaceMemoryProposals(controller.signal).then(
      value => { if (!controller.signal.aborted) setState({ kind: 'ready', value }) },
      error => { if (!controller.signal.aborted) setState({ kind: 'error', message: error instanceof Error ? error.message : String(error) }) },
    )
    return () => controller.abort()
  }, [generation])
  const rows = state.kind === 'ready' ? state.value.proposals : []
  const selected = rows.find(row => row.id === selection) ?? rows[0]
  return html`<section aria-label="공간 기억 제안" data-workspace-memory-proposals class="min-w-0 rounded border border-border p-4">
    <div class="flex flex-wrap justify-between gap-2"><h2>공간 기억 제안</h2>
      <button type="button" onClick=${() => setGeneration(value => value + 1)}>제안 새로 읽기</button></div>
    <p>모델이 작성한 공간 기억 제안입니다. 내용의 사실 여부는 별도로 검증하지 않았습니다.</p>
    ${state.kind === 'loading' ? html`<p role="status">저장된 제안을 읽고 있습니다.</p>` : null}
    ${state.kind === 'error' ? html`<p role="alert">제안을 읽지 못했습니다: ${state.message}</p>` : null}
    ${state.kind === 'ready' && rows.length === 0 ? html`<p>저장된 공간 기억 제안이 없습니다.</p>` : null}
    ${selected ? html`<label>제안 선택 <select class="max-w-full" value=${selected.id} onChange=${(event: Event) => setSelection((event.target as HTMLSelectElement).value)}>
      ${rows.map(row => html`<option value=${row.id}>${row.id}</option>`)}</select></label>
      <p class="break-all">초안 · ${selected.id}</p>
      <${Proposal} key=${selected.id} value=${selected.proposal} />` : null}
  </section>`
}
