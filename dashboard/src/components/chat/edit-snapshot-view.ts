import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchEditSnapshots, type EditSnapshots } from '../../api/edit-snapshots'
import { editSnapshotDiff } from './edit-snapshot-diff'
import { ADMIN_REQUIRED_MESSAGE, isAdminRequired } from '../../api/admin-required'
import { currentStoredTokenRevision } from '../../api/core'
import { storedTokenRevision } from '../../api/token-revision'

type State = { kind: 'idle' } | { kind: 'loading' }
  | { kind: 'loaded'; before: string; after: string; diff: string }
  | { kind: 'error'; message: string }
  | { kind: 'admin-required' }

export function EditSnapshotView({ refs }: { refs: EditSnapshots }) {
  // Remount the comparison when credentials change, discarding plaintext
  // originals and terminating its worker before another session can reuse it.
  const authRevision = storedTokenRevision.value
  return html`<${ScopedEditSnapshotView} key=${authRevision} refs=${refs} authRevision=${authRevision} />`
}

function ScopedEditSnapshotView({ refs, authRevision }: { refs: EditSnapshots; authRevision: number }) {
  const [requested, setRequested] = useState(false)
  const [state, setState] = useState<State>({ kind: 'idle' })
  useEffect(() => {
    if (!requested) return
    const controller = new AbortController()
    setState({ kind: 'loading' })
    void fetchEditSnapshots(refs, controller.signal).then(async result => ({
      ...result, diff: await editSnapshotDiff(result.before, result.after, controller.signal),
    })).then(
      result => { if (!controller.signal.aborted && authRevision === currentStoredTokenRevision()) setState({ kind: 'loaded', ...result }) },
      error => { if (!controller.signal.aborted && authRevision === currentStoredTokenRevision()) setState(isAdminRequired(error)
        ? { kind: 'admin-required' }
        : { kind: 'error', message: error instanceof Error ? error.message : String(error) }) },
    )
    return () => controller.abort()
  }, [requested, refs.before.sha256, refs.before.bytes, refs.after.sha256, refs.after.bytes, authRevision])
  if (state.kind === 'admin-required') return html`<p role="alert" data-access-state="admin-required" class="my-2 text-xs">${ADMIN_REQUIRED_MESSAGE}</p>`
  return html`<div class="my-2" data-edit-snapshot-view>
    <button type="button" class="rounded border border-border px-2 py-1 text-xs"
      aria-expanded=${requested} onClick=${() => setRequested(value => !value)}>
      ${requested ? '편집 원본 닫기' : '편집 전후 원본 보기'}
    </button>
    ${requested && state.kind === 'loading' ? html`<p role="status">편집 원본을 검증하고 diff를 계산하고 있습니다.</p>` : null}
    ${requested && state.kind === 'error' ? html`<p role="alert">${state.message}</p>` : null}
    ${requested && state.kind === 'loaded' ? html`
      <p class="text-xs">저장 당시의 전체 파일입니다. 두 파일의 바이트 수와 SHA-256을 검증했습니다.</p>
      <pre tabIndex=${0} aria-label="편집 원본의 Unified diff" class="max-h-96 overflow-auto whitespace-pre text-xs focus-visible:ring-2 focus-visible:ring-ring">${state.diff}</pre>
      <div class="grid min-w-0 gap-2 md:grid-cols-2">
        ${(['before', 'after'] as const).map(side => html`<section class="min-w-0">
          <div class="text-xs">${side === 'before' ? '편집 전' : '편집 후'} · ${refs[side].bytes} bytes</div>
          <pre tabIndex=${0} aria-label=${side === 'before' ? '편집 전 전체 원본' : '편집 후 전체 원본'}
            class="max-h-96 overflow-auto whitespace-pre text-xs focus-visible:ring-2 focus-visible:ring-ring">${state[side]}</pre>
        </section>`)}
      </div>` : null}
  </div>`
}
