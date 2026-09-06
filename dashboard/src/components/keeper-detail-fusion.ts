import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { CollapsibleSection } from './common/collapsible'
import { TimeAgo } from './common/time-ago'
import { navigate } from '../router'
import { fusionRuns, refreshFusionRuns } from '../store'

// Keeper 상세 안의 Fusion deliberation 목록. registry(fusion-runs) 기반이다.
// board-sink 트랙(fetchDashboardMemory recent 500)은 활발한 board가 하루 만에
// fusion post를 창 밖으로 밀어버린다(2026-09-06 실측: 뒤에서 553번째 줄) — 그
// 창으로는 이 keeper의 run을 읽을 수 없다. registry는 완료분 Latest-64를
// 디스크에 replay하므로 서버 재시작 뒤에도 살아 있고, run마다 keeper가 붙어
// 여기서 바로 필터된다. 질문 원문·패널 상세는 run 상세(fusion 탭)가 가진다.
export function KeeperFusionRuns({ keeperName }: { keeperName: string }) {
  useEffect(() => {
    void refreshFusionRuns()
  }, [keeperName])

  const all = fusionRuns.value
  const runs = useMemo(
    () => all.filter(run => run.keeper === keeperName),
    [all, keeperName],
  )

  // fusion을 쓰지 않는 keeper가 대부분이라, run이 없으면 섹션 자체를 내지
  // 않는다. 빈 접이식 섹션은 상세 페이지의 나머지 정합된 침묵과 어긋난다.
  if (runs.length === 0) return null

  const statusLabel = (status: string): string =>
    status === 'running' ? '진행 중' : status === 'failed' ? '실패' : '완료'

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
              <span class="text-sm text-[var(--color-fg-primary)] leading-snug">
                ${statusLabel(run.status)} · ${run.runId}
                <span class="text-2xs text-[var(--color-fg-muted)]"> (${run.preset})</span>
              </span>
              <span class="shrink-0 text-2xs text-[var(--color-fg-muted)]">
                <${TimeAgo} timestamp=${new Date(run.startedAt * 1000).toISOString()} />
              </span>
            </div>
          </button>
        `)}
      </div>
    <//>
  `
}
