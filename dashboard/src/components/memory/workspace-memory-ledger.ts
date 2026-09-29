import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchWorkspaceMemoryLedger, type WorkspaceMemoryLedger } from '../../api/workspace-memory-ledger'

type State = { kind: 'loading' } | { kind: 'error'; message: string }
  | { kind: 'ready'; value: WorkspaceMemoryLedger }

export function WorkspaceMemoryLedgerPanel() {
  const [generation, setGeneration] = useState(0)
  const [state, setState] = useState<State>({ kind: 'loading' })
  useEffect(() => {
    const controller = new AbortController()
    setState({ kind: 'loading' })
    void fetchWorkspaceMemoryLedger(controller.signal).then(
      value => { if (!controller.signal.aborted) setState({ kind: 'ready', value }) },
      error => { if (!controller.signal.aborted) setState({ kind: 'error', message: error instanceof Error ? error.message : String(error) }) },
    )
    return () => controller.abort()
  }, [generation])
  const value = state.kind === 'ready' ? state.value : null
  const ledger = value?.status === 'available' ? value.ledger : null
  const members = (kind: 'claim' | 'conflict', id: string) =>
    ledger?.facts.filter(row => row.disposition.kind === kind
      && (kind === 'claim' ? row.disposition.kind === 'claim' && row.disposition.claim_id === id
        : row.disposition.kind === 'conflict' && row.disposition.conflict_id === id)) ?? []
  const factRows = (rows: NonNullable<typeof ledger>['facts']) => rows.map(row => html`
    <li class="break-words py-1">
      <span>${row.keeper_id} · ${row.store === 'ordinary' ? '일반 기억' : row.path}</span>
      <p class="m-0 whitespace-pre-wrap">${row.current_claim ?? '현재 원문을 확인할 수 없음'}</p>
      ${row.source_state === 'absent' ? html`<small>현재 스토어에 없음</small>` : null}
      ${row.source_state === 'unavailable' ? html`<small>현재 스토어를 읽지 못함</small>` : null}
    </li>`)
  return html`<section aria-label="공간 기억 원장" data-workspace-memory-ledger class="min-w-0 rounded border border-border p-4">
    <div class="flex flex-wrap justify-between gap-2"><h2>공간 기억 원장</h2>
      <button type="button" onClick=${() => setGeneration(value => value + 1)}>원장 새로 읽기</button></div>
    <p>Keeper 사실을 모델이 분류한 기록입니다. 의미 검증은 수행하지 않았습니다.</p>
    ${state.kind === 'loading' ? html`<p role="status">원장을 읽고 있습니다.</p>` : null}
    ${state.kind === 'error' ? html`<p role="alert">원장을 읽지 못했습니다: ${state.message}</p>` : null}
    ${value?.status === 'missing' ? html`<p>아직 저장된 공간 기억 원장이 없습니다.</p>` : null}
    ${value?.status === 'available' && value.source_resolution.status === 'unavailable'
      ? html`<p role="status">현재 Keeper 원문 조회 실패: ${value.source_resolution.detail}</p>` : null}
    ${ledger ? html`<div class="grid min-w-0 gap-3">
      <p>분류된 사실 ${ledger.facts.length}개 · 공유 주장 ${ledger.claims.length}개 · 충돌 ${ledger.conflicts.length}개</p>
      <section><h3>공유 주장</h3>${ledger.claims.map(row => html`<article class="border-t border-border py-2">
        <p class="whitespace-pre-wrap break-words">${row.claim}</p>
        <ul>${factRows(members('claim', row.claim_id))}</ul>
      </article>`)}</section>
      <section><h3>충돌</h3>${ledger.conflicts.map(row => html`<article class="border-t border-border py-2">
        <p class="whitespace-pre-wrap break-words">${row.description}</p>
        <ul>${factRows(members('conflict', row.conflict_id))}</ul>
      </article>`)}</section>
      <details><summary>제외한 사실 · ${ledger.facts.filter(row => row.disposition.kind === 'excluded').length}개</summary>
        <ul>${ledger.facts.filter(row => row.disposition.kind === 'excluded').map(row => html`<li>
          ${row.keeper_id}: ${row.current_claim ?? '현재 원문을 확인할 수 없음'}
          <p>${row.disposition.kind === 'excluded' ? row.disposition.reason : ''}</p>
        </li>`)}</ul>
      </details>
      <details><summary>원장 전체 데이터</summary><pre tabIndex=${0} class="max-h-96 overflow-auto whitespace-pre-wrap break-words text-xs">${JSON.stringify(value, null, 2)}</pre></details>
    </div>` : null}
  </section>`
}
