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
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { currentSessionEpoch, sessionEpoch } from '../../core/auth'
import { extractObserverTopics, markViewSynced, observerConnected, subscribeObserverFrames, subscribeObserverReconnect, subscribeObserverResync } from '../../core/observer'
import { parseKeeperEntityTab, type KeeperEntityTab } from '../../routes/router'
import type { WorkspaceViewProps } from '../types'
import { KEEPER_ROSTER_OBSERVER_TOPICS, loadKeeperRoster, readKeeperRosterSources } from './keepers-api'
import { KeeperRoster } from './keeper-roster'
import { KeeperHeader } from './keeper-header'
import { KeeperChatTab } from './keeper-chat-tab'
import { KeeperMemoryTab } from './keeper-memory-tab'
import { KeeperPortraitCandleTab } from './keeper-portrait-candle-tab'
import { KeeperWorkSandboxTab } from './keeper-work-sandbox-tab'
import { KeeperConfigTab } from './keeper-config-tab'
import type { KeeperRosterItem } from './types'
import './keepers.css'

export function KeepersWorkspace(props: WorkspaceViewProps) {
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
  const [localSelectedName, setLocalSelectedName] = useState<string | null>(props.entityId ?? null)
  const rosterRead = useRef<ReturnType<typeof loadKeeperRoster> | null>(null)
  const activeTab: KeeperEntityTab = parseKeeperEntityTab(props.entityTab)

  useEffect(() => {
    if (props.entityId) {
      setLocalSelectedName(props.entityId)
    }
  }, [props.entityId])

  const refreshRoster = useCallback(async (reason: 'mount' | 'sse' | 'manual') => {
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
    void refreshRoster('mount')
  }, [epoch, refreshRoster])

  useEffect(() => {
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
  }, [refreshRoster])

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

  return html`
    <div class="kp-root" data-workspace="keepers">
      <${KeeperRoster}
        roster=${roster}
        selectedKeeper=${activeKeeper?.name ?? null}
        onSelectKeeper=${handleSelectKeeper}
        onCreatedKeeper=${handleCreatedKeeper}
      />

      <main class="kp-stage" aria-label="활성 Keeper 상세">
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
              <${KeeperHeader}
                key=${`hdr:${activeKeeper.name}`}
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
                    turnSnapshot=${turns.kind === 'value' ? turns : undefined}
                    onInspect=${props.onInspect}
                    onSelectKeeper=${handleSelectKeeper}
                    onMutated=${() => void refreshRoster('manual')}
                  />
                `}
                ${activeTab === 'memory' && html`
                  <${KeeperMemoryTab}
                    key=${`mem:${activeKeeper.name}`}
                    keeperName=${activeKeeper.name}
                  />
                `}
                ${activeTab === 'portrait-candle' && html`
                  <${KeeperPortraitCandleTab}
                    key=${`pc:${activeKeeper.name}`}
                    keeper=${activeKeeper}
                    onMutated=${() => void refreshRoster('manual')}
                  />
                `}
                ${activeTab === 'work-sandbox' && html`
                  <${KeeperWorkSandboxTab}
                    key=${`ws:${activeKeeper.name}`}
                    keeperName=${activeKeeper.name}
                    onNavigate=${props.onNavigate}
                    onInspect=${props.onInspect}
                  />
                `}
                ${activeTab === 'config' && html`
                  <${KeeperConfigTab}
                    key=${`cfg:${activeKeeper.name}`}
                    keeperName=${activeKeeper.name}
                    onMutated=${() => void refreshRoster('manual')}
                  />
                `}
              </div>
            `}
      </main>
    </div>
  `
}

export default KeepersWorkspace
