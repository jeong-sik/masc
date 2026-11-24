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
import { useCallback, useEffect, useMemo, useState } from 'preact/hooks'
import { currentSessionEpoch } from '../../core/auth'
import { markViewSynced, subscribeObserverFrames } from '../../core/observer'
import { observedLoading, type Observed } from '../../core/resource-cache'
import { parseKeeperEntityTab, type KeeperEntityTab } from '../../routes/router'
import type { WorkspaceViewProps } from '../types'
import { loadKeeperRoster } from './keepers-api'
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
  const [roster, setRoster] = useState<Observed<readonly KeeperRosterItem[]>>(() => observedLoading())
  const [localSelectedName, setLocalSelectedName] = useState<string | null>(props.entityId ?? null)
  const activeTab: KeeperEntityTab = parseKeeperEntityTab(props.entityTab)

  useEffect(() => {
    if (props.entityId) {
      setLocalSelectedName(props.entityId)
    }
  }, [props.entityId])

  const refreshRoster = useCallback(async (reason: 'mount' | 'route' | 'sse' | 'manual') => {
    const startEpoch = currentSessionEpoch()
    const next = await loadKeeperRoster(reason)
    if (currentSessionEpoch() !== startEpoch) return
    setRoster(next)
    markViewSynced()
  }, [])

  useEffect(() => {
    void refreshRoster('mount')
  }, [refreshRoster])

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null
    const unsub = subscribeObserverFrames(() => {
      if (timer) return
      timer = setTimeout(() => {
        timer = null
        void refreshRoster('sse')
      }, 450)
    })
    return () => {
      unsub()
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
                activeTab=${activeTab}
                onSelectTab=${handleSelectTab}
                onLifecycleMutated=${() => void refreshRoster('manual')}
                onDeleted=${handleDeletedKeeper}
              />

              <div class="kp-body">
                ${activeTab === 'chat' && html`
                  <${KeeperChatTab}
                    key=${`chat:${activeKeeper.name}`}
                    keeper=${activeKeeper}
                    onInspect=${props.onInspect}
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
