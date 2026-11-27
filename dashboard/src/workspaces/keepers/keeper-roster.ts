/**
 * Left 260px Virtualized Keeper Roster + `+ Create Keeper` (`target=keeper_create`) Schema Drawer.
 */

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { isWaitingUnavailable } from './turn-context'
import { KeeperTurnElapsed } from './turn-elapsed'
import { useCallback, useEffect, useMemo, useState } from 'preact/hooks'
import { authSession } from '../../core/auth'
import { formatObserved, type Observed } from '../../core/resource-cache'
import { KeeperBadge } from '../../components/keeper-badge'
import { VirtualList } from '../../components/primitives/virtual-list'
import { isAdminLockedForSession } from '../../routes/router'
import {
  filterAndSortRoster,
  formatContextDetail,
  isKeeperPathResting,
  needsRosterAttention,
  observeRosterContextPct,
} from './keepers-api'
import { withObservedTurn, type FleetTurnPreviews } from './fleet-turn-previews'
import { TURN_RUNNING_PHRASE, turnDoing, turnDoingBrief } from './turn-doing'
import { otherCallsLabel } from './turn-open-work'
import type {
  KeeperRosterItem,
  RosterMode,
} from './types'

/** When the running-turn rows were read and whether that read is fresh. */
export interface KeeperTurnsObservation {
  readonly observedAt: number
  readonly live: boolean
}

const LazyCreateKeeperModal = lazy(async () => ({
  default: (await import('./create-keeper-modal')).CreateKeeperModal,
}))
export interface KeeperRosterProps {
  readonly roster: Observed<readonly KeeperRosterItem[]>
  readonly turnsObservation: KeeperTurnsObservation | null
  /** What each Keeper's turn has sent since the turns snapshot. A row lays it
   *  over its own Keeper when it is drawn, so a preview redraws the rows on
   *  screen and leaves the order of the list alone. */
  readonly turnPreviews?: FleetTurnPreviews
  readonly selectedKeeper: string | null
  readonly onSelectKeeper: (name: string) => void
  readonly onCreatedKeeper: (name: string) => void
}

const WAITING_UNREAD_LABEL = '대기 목록 읽기 실패'
const WAITING_UNREAD_MARKER = '대기 ?'

// What a row says about waiting: that the list could not be read, how much
// waits, or nothing.
function waitingWords(k: KeeperRosterItem): string | null {
  if (isWaitingUnavailable(k.waiting_summary)) return WAITING_UNREAD_LABEL
  return k.waiting_summary && k.waiting_summary.count > 0 ? `대기 ${k.waiting_summary.count}` : null
}

// A tool name gives way at its front and keeps this many characters of its
// end: of a qualified name such as `mcp__server__tool` the end tells one call
// from another.
const TOOL_NAME_KEPT_TAIL = 12
// The least room a tool name is given before what follows it on the line is
// left out: the kept end and an ellipsis in front of it.
const TOOL_NAME_LEAST_ROOM = `${TOOL_NAME_KEPT_TAIL + 2}ch`

function frontAndKeptEnd(name: string): readonly [front: string, keptEnd: string] {
  const chars = [...name]
  return chars.length > TOOL_NAME_KEPT_TAIL
    ? [chars.slice(0, -TOOL_NAME_KEPT_TAIL).join(''), chars.slice(-TOOL_NAME_KEPT_TAIL).join('')]
    : [name, '']
}

function healthDotTone(k: KeeperRosterItem): 'ok' | 'warn' | 'bad' | 'brass' | 'idle' {
  if (needsRosterAttention(k)) return 'bad'
  if (isKeeperPathResting(k) || k.paused) return 'warn'
  if (k.active_turn) return 'brass'
  if (k.keepalive_running) return 'ok'
  return 'idle'
}

export function KeeperRoster(props: KeeperRosterProps) {
  const turnsObservation = props.turnsObservation
  const adminLocked = isAdminLockedForSession('admin', authSession.value)
  const [mode, setMode] = useState<RosterMode>('companies')
  const [query, setQuery] = useState('')
  const [createOpen, setCreateOpen] = useState(false)

  useEffect(() => {
    if (adminLocked && createOpen) setCreateOpen(false)
  }, [adminLocked, createOpen])

  const items: readonly KeeperRosterItem[] = props.roster.kind === 'value' ? props.roster.data : []

  const visible = useMemo(
    () => filterAndSortRoster(items, mode, query),
    [items, mode, query],
  )
  const getRosterKey = useCallback((k: KeeperRosterItem) => k.name, [])

  return html`
    <aside class="kp-roster" aria-label="Keeper 로스터">
      <div class="kp-roster-head">
        <div class="kp-roster-top">
          <h2 class="kp-roster-title">
            <span class="kp-roster-title-text" title=${`Keepers (${items.length})`}>
              Keepers (<span class="tnum">${items.length}</span>)
            </span>
            ${props.roster.kind === 'value' && props.roster.stale && html`
              <span class="kp-pill" data-tone="warn">지연됨</span>
            `}
          </h2>
          ${!adminLocked && html`
            <button
              type="button"
              class="btn-primary"
              onClick=${() => setCreateOpen(true)}
            >
              + Create Keeper
            </button>
          `}
        </div>

        <input
          type="search"
          class="kp-input"
          placeholder="Keeper, 회사, 런타임 검색…"
          aria-label="Keeper 검색"
          value=${query}
          onInput=${(e: Event) => setQuery((e.currentTarget as HTMLInputElement).value)}
        />

        <div class="kp-modes" role="group" aria-label="로스터 정렬 모드">
          <button
            type="button"
            class="kp-mode-btn"
            aria-pressed=${mode === 'companies' ? 'true' : 'false'}
            onClick=${() => setMode('companies')}
          >
            Companies
          </button>
          <button
            type="button"
            class="kp-mode-btn"
            aria-pressed=${mode === 'attention' ? 'true' : 'false'}
            onClick=${() => setMode('attention')}
          >
            Attention
          </button>
          <button
            type="button"
            class="kp-mode-btn"
            aria-pressed=${mode === 'wall24h' ? 'true' : 'false'}
            onClick=${() => setMode('wall24h')}
          >
            24h Wall
          </button>
        </div>
      </div>

      ${props.roster.kind === 'loading'
        ? html`<div class="kp-empty">로스터 불러오는 중…</div>`
        : props.roster.kind === 'failed'
          ? html`<div class="ap-error" role="alert">${props.roster.error.message}</div>`
          : html`
              <${VirtualList}
                className="kp-roster-list"
                items=${visible}
                estimateSize=${60}
                height="100%"
                ariaLabel="Keeper 목록"
                getItemKey=${getRosterKey}
                empty=${html`<div class="kp-empty">일치하는 Keeper 없음</div>`}
                renderItem=${(listed: KeeperRosterItem) => {
                  const k = withObservedTurn(listed, props.turnPreviews?.get(listed.name))
                  const ctxObs = observeRosterContextPct(k)
                  const ctxDetail = formatContextDetail(k)
                  const ctxLabel = ctxObs.kind === 'value' ? ctxDetail.label : formatObserved(ctxObs, (v) => `${v}%`)
                  const ctxTone = ctxObs.kind !== 'value'
                    ? undefined
                    : ctxObs.data >= 85
                      ? 'bad'
                      : ctxObs.data >= 65
                        ? 'warn'
                        : 'ok'
                  const resting = isKeeperPathResting(k)
                  const failing = needsRosterAttention(k)
                  const selected = props.selectedKeeper === k.name
                  const waitingUnread = isWaitingUnavailable(k.waiting_summary)
                  const waitingUnreadTitle = waitingUnread && k.waiting_summary.reason
                    ? `${WAITING_UNREAD_LABEL}: ${k.waiting_summary.reason}`
                    : WAITING_UNREAD_LABEL
                  const waiting = waitingWords(k)
                  const waitingCount = waitingUnread ? null : waiting
                  const settled = waiting === null ? k.runtime_id : `${waiting} · ${k.runtime_id}`
                  // A warning or a rest is said before a turn. A row in a turn says
                  // what the turn is doing and how much waits; its runtime is in the
                  // hover and in the header.
                  const turn = !failing && !resting ? k.active_turn : null
                  const turnPreview = turn?.preview ?? null
                  const doing = turn ? turnDoingBrief(turnPreview) : null
                  const subLine = failing
                    ? `⚠ ${k.runtime_blocker_summary ?? k.last_failure?.cause ?? k.directory_issue ?? k.health}`
                    : resting
                      ? `⏸ 휴식 · ${k.runtime_path_rest?.runtime_id ?? k.runtime_id}`
                      : turn
                        ? `${turnPreview ? turnDoing(turnPreview).phrase : TURN_RUNNING_PHRASE} · ${settled}`
                        : settled
                  // How long the turn has run comes first on the state line (#55073).
                  // It stands before the state, kept whole, and the state is laid
                  // out in the room that is left: inside the turn's line it would be
                  // a part that pushes words that do not fit beside it off the line.
                  const elapsed = turnsObservation && k.active_turn && k.active_turn.started_at_unix > 0
                    ? html`<span class="kp-roster-sub kp-roster-elapsed" data-roster-elapsed><${KeeperTurnElapsed}
                        startedAt=${k.active_turn.started_at_unix * 1000}
                        observedAt=${turnsObservation.observedAt}
                        live=${turnsObservation.live}
                      />${' · '}</span>`
                    : null
                  const actionableDisposition =
                    k.operator_disposition && k.operator_disposition !== 'pass'
                      ? k.operator_disposition
                      : null
                  const rightSub = mode === 'wall24h'
                    ? (k.turns_24h_breakdown && k.turns_24h_breakdown.failed > 0
                        ? `${k.turns_24h_breakdown.ok}ok/${k.turns_24h_breakdown.failed}fail`
                        : k.turns_24h !== null
                          ? `${k.turns_24h}t/24h`
                          : '없음')
                    : mode === 'attention' && failing
                      ? `⚠ ${actionableDisposition ?? k.health}`
                      : mode === 'attention' && resting
                        ? '⏸ 휴식'
                        : k.company
                  return html`
                    <button
                      type="button"
                      class="kp-roster-row"
                      data-keeper=${k.name}
                      data-selected=${selected ? 'true' : 'false'}
                      aria-current=${selected ? 'true' : undefined}
                      onClick=${() => props.onSelectKeeper(k.name)}
                    >
                      <span class="kp-roster-avatar">
                        <${KeeperBadge}
                          id=${k.name}
                          size="md"
                          variant="sigil"
                          portrait=${true}
                          beat=${k.active_turn !== null}
                        />
                        <span class="kp-status-dot" data-tone=${healthDotTone(k)} />
                      </span>
                      <span class="kp-roster-text">
                        <span class="kp-roster-line">
                          <span class="kp-roster-name">${k.name}</span>
                          <span class="kp-pill" data-ctx="true" data-tone=${ctxTone} title=${ctxDetail.tooltip}>
                            Ctx ${ctxLabel}
                          </span>
                        </span>
                        <span class="kp-roster-line">
                          <span class="kp-roster-state" data-in-turn=${doing !== null ? 'true' : undefined}>
                            ${elapsed}
                            ${doing === null
                              ? html`<span class="kp-roster-sub" data-roster-state title=${subLine}>${subLine}</span>`
                              : html`
                                  <span
                                    class="kp-roster-sub kp-roster-turn"
                                    data-roster-state
                                    data-waiting-unread=${waitingUnread ? 'true' : undefined}
                                    title=${subLine}
                                  >
                                    ${waitingUnread && html`<span class="kp-roster-waiting-unread" title=${waitingUnreadTitle}>${`${WAITING_UNREAD_MARKER} · `}</span>`}
                                    ${doing.kind === 'words'
                                      ? html`<span class="kp-roster-words">${doing.words}</span>`
                                      : (([front, keptEnd]) => html`
                                          <span
                                            class="kp-roster-tool"
                                            style=${{ flexBasis: waitingUnread ? (doing.otherCalls > 0 ? '6ch' : '0') : TOOL_NAME_LEAST_ROOM }}
                                          >
                                            <span class="kp-roster-tool-front">${front}</span>
                                            ${keptEnd !== '' && html`<span>${keptEnd}</span>`}
                                          </span>
                                          ${doing.otherCalls > 0 && html`<span>${` ${otherCallsLabel(doing.otherCalls)}`}</span>`}
                                        `)(frontAndKeptEnd(doing.name))}
                                    ${waitingCount !== null && html`<span class="kp-roster-waiting">${` · ${waitingCount}`}</span>`}
                                  </span>
                                `}
                          </span>
                          <span class="kp-roster-sub kp-roster-side" title=${rightSub}>${rightSub}</span>
                        </span>
                      </span>
                    </button>
                  `
                }}
              />
            `}

      ${!adminLocked && createOpen && html`
        <${Suspense} fallback=${null}>
          <${LazyCreateKeeperModal}
            onClose=${() => setCreateOpen(false)}
            onCreated=${(name: string) => {
              setCreateOpen(false)
              props.onCreatedKeeper(name)
            }}
          />
        <//>
      `}
    </aside>
  `
}
