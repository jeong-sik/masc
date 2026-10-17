import { html } from 'htm/preact'
import type { BoardAudience, Keeper } from '../../types'
import { keepers as currentKeepers } from '../../store'
import { boardTargetReadings, readBoardAudience } from '../../lib/board-address'
import { RichContent } from '../common/rich-content'

const AUDIENCE_LABEL = {
  broadcast: '전체 Keeper 대상',
  thread_participants: '스레드 참여 대상',
  discoverable: '발견 가능한 게시글',
} as const

/** Board-only address display. The persisted audience, not text matching,
 * selects targets; current effective addresses select matching Keeper lanes.
 * Comments have no persisted audience and explicitly report that gap. */
export function BoardRichContent({ text, audience, previewLimit = 4, keepers = currentKeepers.value }: {
  text: string
  audience?: BoardAudience
  previewLimit?: number
  keepers?: Keeper[]
}) {
  // The dashboard/bootstrap feed also carries Board rows directly. Decode
  // at this shared consumer, not only on the separate direct Board API.
  const reading = readBoardAudience(audience)
  const targets = boardTargetReadings(reading, keepers)
  return html`<div class="flex min-w-0 flex-col gap-2">
    <div class="flex flex-wrap items-center gap-1.5 text-2xs" aria-label="Board 수신 대상">
      ${reading.kind === 'unavailable'
        ? html`<span class="text-[var(--color-fg-muted)]" role=${reading.reason === 'invalid_payload' ? 'alert' : undefined}>
            ${reading.reason === 'invalid_payload' ? '수신 대상 응답을 확인할 수 없습니다' : '저장된 수신 대상 정보 없음'}
          </span>`
        : reading.kind !== 'targets'
          ? html`<span class="text-[var(--color-fg-muted)]">${AUDIENCE_LABEL[reading.kind]}</span>`
          : html`<span class="text-[var(--color-fg-muted)]">현재 수신 대상</span>
              ${targets.map(row => html`<span key=${row.target}
                class=${row.keepers.length > 0
                  ? 'rounded-[var(--r-1)] bg-[var(--accent-15)] px-2 py-0.5 text-[var(--color-accent-fg)] break-all'
                  : 'rounded-[var(--r-1)] border border-[var(--color-border-default)] px-2 py-0.5 text-[var(--color-fg-muted)] break-all'}
                data-board-address=${row.keepers.length > 0 ? 'matched' : row.unresolved ? 'unavailable' : 'unmatched'}>
                @${row.target} · ${row.keepers.length > 0 ? row.keepers.join(', ') : row.unresolved ? '주소 확인 불가' : '일치하는 Keeper 없음'}
              </span>`)}`}
    </div>
    ${targets.some(row => row.unresolved) ? html`<p class="m-0 text-2xs text-[var(--color-fg-muted)]" role="status">일부 Keeper의 현재 수신 주소를 확인할 수 없습니다</p>` : null}
    <${RichContent} text=${text} previewLimit=${previewLimit} />
  </div>`
}
