import { html } from 'htm/preact'
import { runtimeCandidateFaultLabel, type RuntimeLaneObservation } from '../lib/keeper-runtime-walk'
import { TimeAgo } from './common/time-ago'

export function KeeperRuntimeWalkObservation({ observation }: { observation: RuntimeLaneObservation | null }) {
  if (observation === null) return null
  return html`
    <details class="w-full border-t border-[var(--color-border-default)] pt-2">
      <summary class="cursor-pointer">기록된 턴의 런타임 후보 증거</summary>
      ${observation.turn ? html`
        <div class="text-[var(--color-fg-muted)]">
          ${observation.turn.trace_id} · 턴 ${observation.turn.turn_count ?? '미기록'}
          · <${TimeAgo} timestamp=${observation.turn.ended_at} />
        </div>` : null}
      ${observation.state === 'unreadable'
        ? html`<p>후보 증거를 읽을 수 없습니다 · ${observation.error}</p>`
        : observation.state === 'not_observed'
          ? html`<p>이 턴의 후보 경로는 수집되지 않았습니다.</p>`
          : html`
            ${observation.evidence.failures.length === 0 ? html`<p>기록된 후보 오류가 없습니다.</p>` : null}
            <ol class="space-y-2">
              ${observation.evidence.failures.map((failure, index) => html`
                <li key=${index}>
                  <strong>후보 ${failure.attempt + 1} · ${failure.runtime_id}</strong>
                  · ${failure.dispatch === 'dispatched' ? '후보 호출' : '호출 전 거절'}
                  · ${runtimeCandidateFaultLabel(failure.api_candidate_fault)}
                  <p class="whitespace-pre-wrap break-words">${failure.summary}</p>
                </li>`)}
            </ol>
            ${observation.evidence.terminal.kind === 'candidate'
              ? html`<p class="mt-2 whitespace-pre-wrap break-words">
                  <strong>최종 오류 출처 · 후보 ${observation.evidence.terminal.attempt + 1}
                  · ${observation.evidence.terminal.runtime_id}</strong>
                  · ${observation.evidence.terminal.summary}
                </p>`
              : html`<p>후보에서 나온 종단 오류는 관측되지 않았습니다.</p>`}`}
    </details>`
}
