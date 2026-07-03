import { html } from 'htm/preact'
import type {
  KeeperCatchupDigest,
  KeeperCatchupDigestCoverageCause,
} from '../api/schemas/keeper-catchup-digest'
import { KEEPER_DIGEST_MIN_ACTIVITY } from '../config/constants'

// Total count of new activity across every category since the operator's
// last-seen cursor. Drives the "is there anything worth showing" gate.
export function keeperCatchupDigestActivityCount(digest: KeeperCatchupDigest): number {
  const { chat, turns, tasks, board, lifecycle } = digest
  return (
    chat.new_messages +
    chat.transport_failures +
    turns.completed +
    turns.failed +
    turns.crashes +
    tasks.claimed +
    tasks.done +
    tasks.released +
    tasks.cancelled +
    board.posted +
    board.commented +
    board.voted +
    lifecycle.pause_events +
    lifecycle.resume_events
  )
}

function coverageHasLowerBound(
  coverage: KeeperCatchupDigest['coverage'],
): boolean {
  return Object.values(coverage).some(source => source.lower_bound)
}

const COVERAGE_CAUSE_LABELS: Record<KeeperCatchupDigestCoverageCause, string> = {
  chat_page_cap: '채팅 페이지 상한에 도달',
  chat_retention_window: '채팅 보존 기간 밖',
  jsonl_retention_window: '보존 기간 밖',
  crash_scan_cap: '크래시 이벤트 상한에 도달',
}

function coverageWarnings(digest: KeeperCatchupDigest): string[] {
  const sources: ReadonlyArray<readonly [
    string,
    KeeperCatchupDigest['coverage']['chat'],
  ]> = [
    ['채팅', digest.coverage.chat],
    ['턴', digest.coverage.turns],
    ['태스크', digest.coverage.tasks],
    ['보드', digest.coverage.board],
    ['일시정지/재개', digest.coverage.lifecycle],
  ]
  return sources
    .filter(([, source]) => source.lower_bound)
    .map(([label, source]) => {
      const causeLabels = (source.causes ?? []).map(cause => COVERAGE_CAUSE_LABELS[cause])
      return `${label}: ${causeLabels.length > 0 ? causeLabels.join(', ') : '일부 누락 가능'}`
    })
}

// The card renders when there is genuine new activity, when a source read
// failed, or when a source count is a lower bound (fail-visible truncation).
export function shouldShowKeeperCatchupDigest(
  digest: KeeperCatchupDigest | null | undefined,
): digest is KeeperCatchupDigest {
  if (!digest) return false
  return (
    keeperCatchupDigestActivityCount(digest) >= KEEPER_DIGEST_MIN_ACTIVITY ||
    digest.read_errors.length > 0 ||
    coverageHasLowerBound(digest.coverage)
  )
}

interface DigestChip {
  key: string
  text: string
  tone: 'default' | 'warn'
}

const CHIP_BASE =
  'inline-flex items-center rounded-[var(--r-0)] border px-2 py-0.5 text-2xs tabular-nums'
const CHIP_DEFAULT =
  'border-[var(--color-border-default)] bg-[var(--color-bg-page)] text-[var(--color-fg-secondary)]'
const CHIP_WARN = 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--warn-bright)]'

function digestChips(digest: KeeperCatchupDigest): DigestChip[] {
  const { chat, turns, tasks, board, lifecycle } = digest
  const chips: DigestChip[] = []
  if (chat.new_messages > 0) chips.push({ key: 'messages', text: `메시지 ${chat.new_messages}`, tone: 'default' })
  if (turns.completed > 0) chips.push({ key: 'turns', text: `턴 ${turns.completed}회`, tone: 'default' })
  const taskTotal = tasks.claimed + tasks.done + tasks.released + tasks.cancelled
  if (taskTotal > 0) chips.push({ key: 'tasks', text: `태스크 ${taskTotal}`, tone: 'default' })
  const boardTotal = board.posted + board.commented + board.voted
  if (boardTotal > 0) chips.push({ key: 'board', text: `보드 ${boardTotal}`, tone: 'default' })
  const lifecycleTotal = lifecycle.pause_events + lifecycle.resume_events
  if (lifecycleTotal > 0) chips.push({ key: 'lifecycle', text: `일시정지/재개 ${lifecycleTotal}`, tone: 'default' })
  // Warn-toned chips for failure signals; kept distinct from the neutral counts.
  if (turns.failed > 0) chips.push({ key: 'turns-failed', text: `턴 실패 ${turns.failed}`, tone: 'warn' })
  if (turns.crashes > 0) chips.push({ key: 'turns-crashes', text: `크래시 ${turns.crashes}`, tone: 'warn' })
  if (chat.transport_failures > 0) chips.push({ key: 'transport', text: `전송 실패 ${chat.transport_failures}`, tone: 'warn' })
  return chips
}

// Since-last-seen digest card. Rendered OUTSIDE the transcript scroller (above
// the ChatTranscript call sites) so injecting it never perturbs the scroller's
// autoscroll signature. Anchors on digest.since_unix — the frozen baseline the
// server echoed — independent of the live cursor.
export function KeeperCatchupDigestCard({ digest }: { digest: KeeperCatchupDigest }) {
  const chips = digestChips(digest)
  const coverageWarningItems = coverageWarnings(digest)
  return html`
    <div
      data-keeper-catchup-digest
      class="rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2.5 v2-monitoring-panel"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <span class="text-2xs font-semibold uppercase tracking-4 text-[var(--color-fg-muted)]">그 사이 활동</span>
          ${digest.chat.new_messages > 0
            ? html`<span class="text-2xs text-[var(--color-fg-secondary)]">이후 ${digest.chat.new_messages}개 메시지</span>`
            : null}
        </div>
        ${digest.lifecycle.paused_now
          ? html`<span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-2 py-0.5 text-2xs font-medium text-[var(--warn-bright)]">일시정지됨</span>`
          : null}
      </div>
      ${chips.length > 0
        ? html`
            <div class="mt-2 flex flex-wrap items-center gap-1.5">
              ${chips.map(chip => html`
                <span
                  key=${chip.key}
                  class=${`${CHIP_BASE} ${chip.tone === 'warn' ? CHIP_WARN : CHIP_DEFAULT}`}
                >
                  ${chip.text}
                </span>
              `)}
            </div>
          `
        : null}
      ${digest.read_errors.length > 0
        ? html`
            <div class="mt-2 rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-2 py-1 text-2xs leading-relaxed text-[var(--warn-bright)]">
              읽기 오류 (일부 카운트가 누락됐을 수 있습니다): ${digest.read_errors.join(', ')}
            </div>
          `
        : null}
      ${coverageWarningItems.length > 0
        ? html`
            <div class="mt-2 rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-2 py-1 text-2xs leading-relaxed text-[var(--warn-bright)]">
              일부 저장소가 생략되어 카운트가 하한값일 수 있습니다: ${coverageWarningItems.join('; ')}
            </div>
          `
        : null}
    </div>
  `
}
