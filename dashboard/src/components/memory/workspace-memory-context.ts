import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchWorkspaceMemoryContext, type WorkspaceMemoryContext, type WorkspaceMemoryStore } from '../../api/workspace-memory-context'

type State = { kind: 'loading' } | { kind: 'error'; message: string }
  | { kind: 'ready'; value: WorkspaceMemoryContext }

function MemoryStore({ store, label }: { store: WorkspaceMemoryStore; label: string }) {
  if (store.status === 'missing') return html`<section><h4>${label}</h4><p>저장된 기억이 없습니다.</p></section>`
  if (store.status === 'unavailable') return html`<section><h4>${label}</h4><p role="alert">읽기 실패: ${store.detail}</p></section>`
  return html`<section class="min-w-0">
    <h4>${label} · revision ${store.snapshot.revision} · ${store.snapshot.facts.length}개</h4>
    <p>저장 시각 ${new Date(store.snapshot.updated_at * 1000).toLocaleString()}</p>
    ${store.snapshot.facts.length === 0 ? html`<p>현재 선택된 기억이 없습니다.</p>` : null}
    <ul class="list-disc pl-5">
      ${store.snapshot.facts.map(fact => html`<li><pre class="whitespace-pre-wrap break-words text-sm">${fact.claim}</pre></li>`)}
    </ul>
    <details><summary>현재 저장 원문·최근 변경</summary>
      <pre tabIndex=${0} aria-label=${`${label} 저장 원문`} class="max-h-96 overflow-auto whitespace-pre-wrap break-words text-xs">${JSON.stringify(store.snapshot, null, 2)}</pre>
    </details>
  </section>`
}

export function WorkspaceMemoryContextPanel() {
  const [generation, setGeneration] = useState(0)
  const [state, setState] = useState<State>({ kind: 'loading' })
  const [keeper, setKeeper] = useState('')
  useEffect(() => {
    const controller = new AbortController()
    setState({ kind: 'loading' })
    void fetchWorkspaceMemoryContext(controller.signal).then(
      value => { if (!controller.signal.aborted) setState({ kind: 'ready', value }) },
      error => { if (!controller.signal.aborted) setState({ kind: 'error', message: error instanceof Error ? error.message : String(error) }) },
    )
    return () => controller.abort()
  }, [generation])
  const data = state.kind === 'ready' ? state.value : null
  const selectedKeeper = data?.keepers.some(entry => entry.keeper_id === keeper) ? keeper : ''
  return html`<section class="min-w-0 rounded border border-border p-4" aria-label="공간의 Keeper 기억" data-workspace-memory-context>
    <div class="flex flex-wrap items-center justify-between gap-2">
      <h2>공간의 Keeper 기억</h2>
      <button type="button" onClick=${() => setGeneration(value => value + 1)}>새로 읽기</button>
    </div>
    <p>Keeper별로 저장된 기억을 함께 봅니다. 서로 다른 주장은 그대로 표시하며, 연결된 파일의 현재 내용은 이번 조회에서 재검증하지 않았습니다.</p>
    ${state.kind === 'loading' ? html`<p role="status">기억 원문을 읽고 있습니다.</p>` : null}
    ${state.kind === 'error' ? html`<p role="alert">기억을 읽지 못했습니다: ${state.message}</p>` : null}
    ${data ? html`
      <p>${data.keepers.length}명의 Keeper · 조회 ${new Date(data.generated_at * 1000).toLocaleString()}</p>
      <p>저장소별 스냅샷을 각각 읽었습니다. 모든 기억이 같은 시점의 상태를 나타내지는 않으며, 저장 시각은 각 저장소에 표시됩니다.</p>
      ${data.discovery.status === 'unavailable' ? html`<p role="alert">Keeper 목록을 읽지 못했습니다: ${data.discovery.detail}</p>` : null}
      ${data.discovery.status === 'available' && data.keepers.length === 0 ? html`<p>이 공간에는 조회할 Keeper 기억이 없습니다.</p>` : null}
      <label>Keeper 선택 <select value=${selectedKeeper} onChange=${(event: Event) => setKeeper((event.target as HTMLSelectElement).value)}>
        <option value="">전체 Keeper</option>
        ${data.keepers.map(entry => html`<option value=${entry.keeper_id}>${entry.keeper_id}</option>`)}
      </select></label>
      <div class="grid gap-4">
        ${data.keepers.filter(entry => selectedKeeper === '' || entry.keeper_id === selectedKeeper).map(entry => html`
          <article class="min-w-0 border-t border-border pt-3" data-memory-owner=${entry.keeper_id}>
            <h3 class="break-all">${entry.keeper_id}</h3>
            <div class="grid min-w-0 gap-3 lg:grid-cols-2">
              <${MemoryStore} store=${entry.ordinary} label="일반 기억" />
              <${MemoryStore} store=${entry.source_bound} label="파일 출처 기억" />
            </div>
          </article>`)}
      </div>` : null}
  </section>`
}
