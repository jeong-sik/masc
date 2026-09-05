import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { CollapsibleSection } from './common/collapsible'
import { TimeAgo } from './common/time-ago'
import { buildFusionRuns } from './fusion/fusion-surface'
import { navigate } from '../router'
import { fusionBoardPosts, refreshFusionBoard } from '../store'

// Keeper 상세 안의 Fusion deliberation 목록. 대화 첫 창(max_history 100행)은
// fusion 결론 카드가 하루 만에 밀려나 있는 가장 흔한 이유라(2026-09-05 실측:
// 뒤에서 107번째 줄), 이 keeper의 run을 상세에서 바로 가리킨다.
// post→run 해석은 fusion 서피스의 buildFusionRuns를 그대로 쓴다 — 이 판별이
// 두 벌이 되면 어느 한쪽만 새 증거 모양을 따라가는 drift가 생긴다.
export function KeeperFusionRuns({ keeperName }: { keeperName: string }) {
  useEffect(() => {
    void refreshFusionBoard()
  }, [keeperName])

  const posts = fusionBoardPosts.value
  const runs = useMemo(
    () => buildFusionRuns(posts).filter(run => run.keeperName === keeperName),
    [posts, keeperName],
  )

  // fusion을 쓰지 않는 keeper가 대부분이라, run이 없으면 섹션 자체를 내지
  // 않는다. 빈 접이식 섹션은 상세 페이지의 나머지 정합된 침묵과 어긋난다.
  if (runs.length === 0) return null

  return html`
    <${CollapsibleSection} title="Fusion deliberations (${runs.length})" open=${false}>
      <div class="flex flex-col gap-2" data-testid="keeper-fusion-runs">
        ${runs.map(run => html`
          <button
            key=${run.runId}
            type="button"
            class="text-left border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2.5 rounded-[var(--r-1)] hover:bg-[var(--color-bg-hover)] hover:border-[var(--color-border-strong)] transition-colors"
            data-run-id=${run.runId}
            onClick=${() => navigate('fusion', { run_id: run.runId })}
          >
            <div class="flex items-baseline justify-between gap-3">
              <span class="text-sm text-[var(--color-fg-primary)] leading-snug">${run.question}</span>
              <span class="shrink-0 text-2xs text-[var(--color-fg-muted)]"><${TimeAgo} timestamp=${run.updatedAt} /></span>
            </div>
          </button>
        `)}
      </div>
    <//>
  `
}
