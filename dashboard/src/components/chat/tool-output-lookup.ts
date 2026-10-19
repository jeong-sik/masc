import { createContext } from 'preact'
import { useContext, useEffect } from 'preact/hooks'
import { html } from 'htm/preact'
import { storedTokenRevision } from '../../api/token-revision'
import { ADMIN_REQUIRED_MESSAGE } from '../../api/admin-required'
import { exactToolOutputResetRevision, lookupExactToolOutput, retryExactToolOutput,
  subscribeExactToolOutput, toolCallOutputHydrationContract } from '../../tool-call-output-store'
import { useInViewOnce } from '../common/use-in-view'

// Scope comes from the selected Keeper, never its mutable display label.
export const KeeperToolOutputScope = createContext<string | null>(null)

export function useToolOutputLookup(executionId: string | null | undefined) {
  const keeper = useContext(KeeperToolOutputScope)
  const authRevision = storedTokenRevision.value
  const [ref, inView] = useInViewOnce<HTMLDivElement>()
  const state = lookupExactToolOutput(keeper, executionId)
  const resetRevision = exactToolOutputResetRevision.value
  // A bulk hydration that succeeds is new ledger evidence, so a row that has
  // not loaded asks again once per success. State changes themselves do not
  // restart the subscription, so publishing loading cannot create a retry loop.
  // `coveredThroughMs` only grows on success, unlike `completedAtMs`, which
  // also moves on a failed hydration and on every tool call of a live turn.
  const hydratedThrough = keeper ? toolCallOutputHydrationContract(keeper).coveredThroughMs : null
  useEffect(() => {
    if (!keeper || !executionId || !inView) return
    return subscribeExactToolOutput(keeper, executionId, authRevision, hydratedThrough)
  }, [keeper, executionId, inView, authRevision, hydratedThrough, resetRevision])
  return { ref, output: state.kind === 'loaded' ? state.entry : null,
    state,
    retry: () => retryExactToolOutput(keeper, executionId) }
}

export function ToolOutputLookupNotice({ lookup }: { lookup: ReturnType<typeof useToolOutputLookup> }) {
  const { state } = lookup
  if (state.kind === 'idle' || state.kind === 'loaded') return null
  if (state.kind === 'admin-required') return html`<p role="alert" data-access-state="admin-required" class="m-2 text-xs">${ADMIN_REQUIRED_MESSAGE}</p>`
  if (state.kind === 'loading') return html`<p role="status" class="m-2 text-xs">저장된 실행 기록을 불러오고 있습니다.</p>`
  const message = state.kind === 'missing' ? '저장된 실행 기록을 찾지 못했습니다.'
    : state.kind === 'ambiguous' ? '실행 기록이 중복되어 이 도구의 결과를 확정할 수 없습니다.'
    : '저장된 실행 기록을 불러오지 못했습니다.'
  return html`<div class="m-2 text-xs" role="alert">${message}
    <button type="button" class="ml-2 underline" onClick=${lookup.retry}>다시 조회</button>
  </div>`
}
