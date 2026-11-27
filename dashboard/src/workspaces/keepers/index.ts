/**
 * Workspace 2: `4 Keepers` (`/keepers`, `/keepers/:name/{chat,memory,portrait-candle,work-sandbox,config}`)
 *
 * Flattened 2-Pane Workspace:
 * - Left 260px virtualized Keeper Roster (`Companies | Attention | 24h Wall`, search,
 *   32px portrait + fixed kSigil, status dot, runtime, Ctx % pill, `+ Create Keeper`)
 * - Right Active Keeper Detail:
 *   - 48px `portrait.png` Hero with Candle Brass 14% halo + lifecycle controls
 *   - 5 Entity Tabs: `Chat` (+ Opt-In Right Debug Companion `⌘.`), `Memory`,
 *     `Portrait & Candle`, `Work & Sandbox`, `Config`.
 */

import { html } from 'htm/preact'
import { Suspense } from 'preact/compat'
import { computed, useSignal, type ReadonlySignal } from '@preact/signals'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { authSession, currentSessionEpoch, isSingleUserMember, sessionEpoch } from '../../core/auth'
import { extractObserverTopics, markViewSynced, observerConnected, subscribeObserverFrames, subscribeObserverReconnect, subscribeObserverResync } from '../../core/observer'
import { createPreloadableLazy } from '../../lib/lazy-component'
import { parseKeeperEntityTab, type KeeperEntityTab } from '../../routes/router'
import { registerSubroutePreloader } from '../registry'
import type { WorkspaceViewProps } from '../types'
import {
  KEEPER_ROSTER_OBSERVER_TOPICS,
  loadKeeperRoster,
  parseKeeperTurnPreviewEvent,
  readKeeperRosterSources,
} from './keepers-api'
import {
  NO_FLEET_TURN_PREVIEWS,
  retainFleetTurnPreview,
  withObservedTurn,
  type FleetTurnPreviews,
} from './fleet-turn-previews'
import { KeeperRoster } from './keeper-roster'
import { KeeperHeader, type KeeperHeaderProps } from './keeper-header'
import { KeeperChatTab } from './keeper-chat-tab'
import { PersonalKeepersWorkspace } from './personal-keepers-workspace'
import type { KeeperRosterItem } from './types'
import './keepers.css'

const keeperMemoryTab = createPreloadableLazy<{ readonly keeperName: string }>(
  async () => (await import('./keeper-memory-tab')).KeeperMemoryTab,
)
const keeperPortraitCandleTab = createPreloadableLazy<{
  readonly keeper: KeeperRosterItem
  readonly onMutated: () => void
}>(async () => (await import('./keeper-portrait-candle-tab')).KeeperPortraitCandleTab)
const keeperWorkSandboxTab = createPreloadableLazy<{
  readonly keeperName: string
  readonly onNavigate: WorkspaceViewProps['onNavigate']
  readonly onInspect: WorkspaceViewProps['onInspect']
}>(async () => (await import('./keeper-work-sandbox-tab')).KeeperWorkSandboxTab)
const keeperConfigTab = createPreloadableLazy<{
  readonly keeperName: string
  readonly onMutated: () => void
}>(async () => (await import('./keeper-config-tab')).KeeperConfigTab)

export function preloadKeeperEntityTab(tab: KeeperEntityTab | string): Promise<void> {
  switch (parseKeeperEntityTab(tab)) {
    case 'memory':
      return keeperMemoryTab.preload()
    case 'portrait-candle':
      return keeperPortraitCandleTab.preload()
    case 'work-sandbox':
      return keeperWorkSandboxTab.preload()
    case 'config':
      return keeperConfigTab.preload()
    default:
      return Promise.resolve()
  }
}

registerSubroutePreloader('keepers', (tab) => {
  void preloadKeeperEntityTab(tab).catch(() => {})
})

interface ObservedTurns {
  readonly turnPreviews: ReadonlySignal<FleetTurnPreviews>
}

// The header with its Keeper's turn as the stream last described it. It is a
// component of its own and follows its own Keeper's previews, so a preview
// redraws the header of the Keeper it is about and nothing else.
function ObservedKeeperHeader({ turnPreviews, keeper, ...rest }: KeeperHeaderProps & ObservedTurns) {
  const name = keeper.name
  const received = useMemo(() => computed(() => turnPreviews.value.get(name)), [turnPreviews, name])
  return html`<${KeeperHeader} ...${rest} keeper=${withObservedTurn(keeper, received.value)} />`
}
export function KeepersWorkspace(props: WorkspaceViewProps) {
  const session = authSession.value
  const isSingleUser = isSingleUserMember(session)
  const epoch = sessionEpoch.value
  const { roster: listing, turns } = readKeeperRosterSources()
  const roster = useMemo(() => {
    if (listing.kind !== 'value' || turns.kind !== 'value') return listing
    return {
      ...listing,
      data: listing.data.map((keeper) => {
        const turn = turns.data.get(keeper.name)
        return turn
          ? {
              ...keeper,
              active_turn: turn.active,
              chat_control_token: turn.chat_control_token,
              waiting_summary: turn.waiting,
            }
          : keeper
      }),
    }
  }, [listing, turns])
  // The merged roster carries the listing's read time, so the running-turn
  // rows' own read time and freshness travel beside it.
  const turnsObservation = turns.kind === 'value'
    ? { observedAt: turns.updatedAt, live: !turns.stale }
    : null
  const [localSelectedName, setLocalSelectedName] = useState<string | null>(props.entityId ?? null)
  const rosterRead = useRef<ReturnType<typeof loadKeeperRoster> | null>(null)
  const activeTab: KeeperEntityTab = parseKeeperEntityTab(props.entityTab)

  useEffect(() => {
    if (props.entityId) {
      setLocalSelectedName(props.entityId)
    }
  }, [props.entityId])

  const refreshRoster = useCallback(async (reason: 'mount' | 'sse' | 'manual') => {
    if (!isSingleUserMember(authSession.peek())) return
    const startEpoch = currentSessionEpoch()
    // Wait for any superseded read before starting a replacement snapshot.
    if (reason === 'sse' && rosterRead.current) await rosterRead.current
    if (currentSessionEpoch() !== startEpoch) return
    const read = loadKeeperRoster(reason)
    rosterRead.current = read
    await read
    if (rosterRead.current === read) rosterRead.current = null
    if (currentSessionEpoch() !== startEpoch) return
    markViewSynced()
  }, [])

  useEffect(() => {
    if (!isSingleUser) return
    void refreshRoster('mount')
  }, [epoch, isSingleUser, refreshRoster])

  useEffect(() => {
    if (!isSingleUser) return
    let timer: ReturnType<typeof setTimeout> | null = null
    let pending = false
    let running = false
    let disposed = false
    const schedule = () => {
      if (disposed) return
      pending = true
      if (running || timer !== null) return
      timer = setTimeout(() => {
        timer = null
        pending = false
        running = true
        void refreshRoster('sse').finally(() => {
          running = false
          if (pending) schedule()
        })
      }, 450)
    }
    const unsub = subscribeObserverFrames((frame) => {
      if (extractObserverTopics(frame).some((topic) => KEEPER_ROSTER_OBSERVER_TOPICS.includes(topic))) {
        schedule()
      }
    })
    const unsubResync = subscribeObserverResync(schedule)
    const unsubReconnect = subscribeObserverReconnect(schedule)
    let wasConnected = observerConnected.peek()
    const unsubConnection = observerConnected.subscribe((connected) => {
      if (connected && !wasConnected) schedule()
      wasConnected = connected
    })
    return () => {
      disposed = true
      unsub()
      unsubResync()
      unsubReconnect()
      unsubConnection()
      if (timer) clearTimeout(timer)
    }
  }, [isSingleUser, refreshRoster])

  // The turns snapshot is read again only when a turn begins or ends. What a
  // turn does in between arrives here. A preview is kept across a gap in the
  // stream: it is laid over a turn only when it carries that turn's own owner
  // key and a revision past the snapshot's, and the server keys each turn anew.
  const fleetTurnPreviews = useSignal<FleetTurnPreviews>(NO_FLEET_TURN_PREVIEWS)
  useEffect(() => {
    // A preview belongs to the session that received it.
    fleetTurnPreviews.value = NO_FLEET_TURN_PREVIEWS
    return subscribeObserverFrames((frame) => {
      const event = parseKeeperTurnPreviewEvent(frame.event, frame.data)
      if (!event) return
      fleetTurnPreviews.value = retainFleetTurnPreview(fleetTurnPreviews.peek(), event.keeperName, {
        ownerKey: event.ownerKey,
        preview: event.preview,
        receivedAt: Date.now(),
        live: true,
      })
    })
  }, [epoch, fleetTurnPreviews])

  const rosterItems: readonly KeeperRosterItem[] = roster.kind === 'value' ? roster.data : []

  const activeKeeper = useMemo<KeeperRosterItem | null>(() => {
    if (rosterItems.length === 0) return null
    const wanted = props.entityId ?? localSelectedName
    if (wanted) {
      const exact = rosterItems.find((k) => k.name === wanted)
      if (exact) return exact
      // Entity route with explicit keeper id must not fall back to first roster row
      // (wrong keeper would hide the requested error detail during load window).
      if (props.entityId) return null
    }
    return rosterItems[0] ?? null
  }, [rosterItems, props.entityId, localSelectedName])

  const handleSelectKeeper = useCallback(
    (name: string) => {
      setLocalSelectedName(name)
      props.onNavigate(`/keepers/${encodeURIComponent(name)}/${activeTab}`)
    },
    [props, activeTab],
  )

  const handleSelectTab = useCallback(
    (tab: KeeperEntityTab) => {
      if (!activeKeeper) return
      props.onNavigate(`/keepers/${encodeURIComponent(activeKeeper.name)}/${tab}`)
    },
    [props, activeKeeper],
  )

  const handleCreatedKeeper = useCallback(
    (name: string) => {
      setLocalSelectedName(name)
      void refreshRoster('manual')
      props.onNavigate(`/keepers/${encodeURIComponent(name)}/chat`)
    },
    [props, refreshRoster],
  )

  const handleDeletedKeeper = useCallback(() => {
    setLocalSelectedName(null)
    void refreshRoster('manual')
    props.onNavigate('/keepers')
  }, [props, refreshRoster])

  if (session.kind === 'multi_account_signed_in') {
    return html`
      <${PersonalKeepersWorkspace}
        key=${`ma:${epoch}:${session.accountId}`}
        session=${session}
        subroute=${props.subroute}
        entityId=${props.entityId}
        entityTab=${props.entityTab}
        onNavigate=${props.onNavigate}
        onInspect=${props.onInspect}
      />
    `
  }

  if (!isSingleUser) {
    return html`
      <div class="kp-root" data-workspace="keepers">
        <section class="kp-stage" aria-label="Keeper 워크스페이스">
          <div class="kp-scroll-pane">
            <div class="kp-card" data-testid="keepers-mode-notice" role="status">
              <h3>Keepers Workspace</h3>
              <p class="kp-roster-sub">
                현재 세션 상태에서는 Keeper 목록을 조회할 수 없습니다. 싱글유저 로컬 세션 또는 멀티 계정 로그인 후 이용하세요.
              </p>
            </div>
          </div>
        </section>
      </div>
    `
  }

  return html`
    <div class="kp-root" data-workspace="keepers">
      <${KeeperRoster}
        roster=${roster}
        turnsObservation=${turnsObservation}
        selectedKeeper=${activeKeeper?.name ?? null}
        onSelectKeeper=${handleSelectKeeper}
        onCreatedKeeper=${handleCreatedKeeper}
      />

      <section class="kp-stage" aria-label="Keeper 워크스페이스">
        ${!activeKeeper
          ? html`
              <div class="kp-scroll-pane">
                <div class="kp-empty">
                  ${roster.kind === 'loading'
                    ? 'Keeper 목록 불러오는 중…'
                    : '표시할 Keeper를 선택하거나 "+ Create Keeper"로 새로 만드세요.'}
                </div>
              </div>
            `
          : html`
              <${ObservedKeeperHeader}
                key=${`hdr:${epoch}:${activeKeeper.name}`}
                turnPreviews=${fleetTurnPreviews}
                keeper=${activeKeeper}
                turnStatus=${turns.kind}
                activeTab=${activeTab}
                onSelectTab=${handleSelectTab}
                onLifecycleMutated=${() => void refreshRoster('manual')}
                onDeleted=${handleDeletedKeeper}
              />

              <div class="kp-body">
                ${activeTab === 'chat' && html`
                  <${KeeperChatTab}
                    key=${`chat:${epoch}:${activeKeeper.name}`}
                    keeper=${activeKeeper}
                    turnSnapshot=${turns}
                    onInspect=${props.onInspect}
                    onSelectKeeper=${handleSelectKeeper}
                    onMutated=${() => void refreshRoster('manual')}
                  />
                `}
                ${activeTab !== 'chat' && html`
                  <${Suspense} fallback=${null}>
                    ${activeTab === 'memory' && html`
                      <${keeperMemoryTab.Component}
                        key=${`mem:${epoch}:${activeKeeper.name}`}
                        keeperName=${activeKeeper.name}
                      />
                    `}
                    ${activeTab === 'portrait-candle' && html`
                      <${keeperPortraitCandleTab.Component}
                        key=${`pc:${epoch}:${activeKeeper.name}`}
                        keeper=${activeKeeper}
                        onMutated=${() => void refreshRoster('manual')}
                      />
                    `}
                    ${activeTab === 'work-sandbox' && html`
                      <${keeperWorkSandboxTab.Component}
                        key=${`ws:${epoch}:${activeKeeper.name}`}
                        keeperName=${activeKeeper.name}
                        onNavigate=${props.onNavigate}
                        onInspect=${props.onInspect}
                      />
                    `}
                    ${activeTab === 'config' && html`
                      <${keeperConfigTab.Component}
                        key=${`cfg:${epoch}:${activeKeeper.name}`}
                        keeperName=${activeKeeper.name}
                        onMutated=${() => void refreshRoster('manual')}
                      />
                    `}
                  <//>
                `}
              </div>
            `}
      </section>
    </div>
  `
}

export default KeepersWorkspace
