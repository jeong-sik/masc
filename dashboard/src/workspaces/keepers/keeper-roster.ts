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
  readonly selectedKeeper: string | null
  readonly onSelectKeeper: (name: string) => void
  readonly onCreatedKeeper: (name: string) => void
}

function waitingSubLine(k: KeeperRosterItem): string {
  if (isWaitingUnavailable(k.waiting_summary)) return `대기 목록 읽기 실패 · ${k.runtime_id}`
  return k.waiting_summary && k.waiting_summary.count > 0
    ? `대기 ${k.waiting_summary.count} · ${k.runtime_id}`
    : k.runtime_id
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
                renderItem=${(k: KeeperRosterItem) => {
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
                  const subLine = failing
                    ? `⚠ ${k.runtime_blocker_summary ?? k.last_failure?.cause ?? k.directory_issue ?? k.health}`
                    : resting
                      ? `⏸ 휴식 · ${k.runtime_path_rest?.runtime_id ?? k.runtime_id}`
                      : waitingSubLine(k)
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
                      <span class="kp-roster-info">
                        <span class="kp-roster-name">${k.name}</span>
                        <span class="kp-roster-sub" title=${subLine}>
                          ${turnsObservation && k.active_turn && k.active_turn.started_at_unix > 0 && html`
                            <${KeeperTurnElapsed}
                              startedAt=${k.active_turn.started_at_unix * 1000}
                              observedAt=${turnsObservation.observedAt}
                              live=${turnsObservation.live}
                            />${' · '}`}${subLine}
                        </span>
                      </span>
                      <span class="kp-roster-right">
                        <span class="kp-pill" data-ctx="true" data-tone=${ctxTone} title=${ctxDetail.tooltip}>
                          Ctx ${ctxLabel}
                        </span>
                        <span class="kp-roster-sub" title=${rightSub}>
                          ${rightSub}
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
