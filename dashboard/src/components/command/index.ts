import { html } from 'htm/preact'
import { EmptyState } from '../common/empty-state'
import { useEffect } from 'preact/hooks'
import {
  commandPlaneActionError,
  commandPlaneError,
  commandPlaneLoading,
  commandPlaneSnapshot,
  commandPlaneSurface,
  focusCommandPlaneChainOperation,
  refreshCommandPlaneChainSummary,
  refreshCommandPlaneCurrentSurface,
  refreshCommandPlaneHelp,
  refreshCommandPlaneOrchestra,
  refreshCommandPlaneSwarm,
  runCommandPlaneDispatchTick,
  setCommandPlaneSurface,
} from '../../command-store'
import { refreshRoomTruth } from '../../room-truth-store'
import { refreshOperatorSnapshot } from '../../operator-store'
import { navigate, route } from '../../router'
import { RoomTruthStrip } from '../common/room-truth-strip'
import {
  commandSurfaceForContext,
  workflowContextForRoute,
} from '../../workflow-context'
import {
  actionDisabled,
  CHAIN_SSE_EVENT_TYPES,
  chainEventsUrl,
  COMMAND_SURFACE_GROUPS,
  COMMAND_SURFACE_META,
  fire,
  isCommandSurface,
  surfaceRouteParams,
} from './helpers'
import { CommandEntryStrip, CommandWorkflowBanner } from './summary-hero'
import { DetailLoadingState, SummarySurface } from './guided-panel'
import { OrchestraSurface } from './orchestra'
import { WarRoomSurface } from './war-room'
import { SwarmSurface } from './swarm'
import { ChainsSurface, OperationsSurface } from './operations'
import { AlertsSurface, TopologySurface, TraceSurface } from './topology'
import { ControlSurface } from './control'

function SurfaceTabs() {
  return html`
    <div class="cmd-surface-tabs flex-col gap-3">
      ${COMMAND_SURFACE_GROUPS.map(group => html`
        <div class="flex flex-col gap-1.5" key=${group.id}>
          <span class="text-[length:var(--fs-xs)] font-semibold text-[color:var(--white-40)] uppercase tracking-[0.04em] pl-1">${group.label}</span>
          <div class="flex flex-wrap gap-2">
            ${COMMAND_SURFACE_META
              .filter(surface => surface.group === group.id)
              .map(surface => html`
                <button
                  class="border border-[var(--white-12)] bg-[var(--white-4)] text-[color:var(--white-72)] p-[8px_14px] capitalize rounded-full cmd-surface-tab ${commandPlaneSurface.value === surface.id ? 'active' : ''}"
                  onClick=${() => {
                    setCommandPlaneSurface(surface.id)
                    navigate('operations', surfaceRouteParams(surface.id))
                  }}
                >
                  ${surface.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `
}

function SurfaceBody({ wallboard = false }: { wallboard?: boolean }) {
  if (commandPlaneSurface.value === 'warroom') {
    return html`<${WarRoomSurface} wallboard=${wallboard} />`
  }
  if (commandPlaneSurface.value === 'summary') {
    return html`<${SummarySurface} />`
  }
  if (commandPlaneSurface.value === 'orchestra') {
    return html`<${OrchestraSurface} />`
  }
  if (commandPlaneSurface.value === 'swarm') {
    return html`<${SwarmSurface} />`
  }
  if (!commandPlaneSnapshot.value) {
    return html`<${DetailLoadingState} />`
  }
  switch (commandPlaneSurface.value) {
    case 'chains':
      return html`<${ChainsSurface} />`
    case 'topology':
      return html`<${TopologySurface} />`
    case 'alerts':
      return html`<${AlertsSurface} />`
    case 'trace':
      return html`<${TraceSurface} />`
    case 'control':
      return html`<${ControlSurface} />`
    case 'operations':
    default:
      return html`<${OperationsSurface} />`
  }
}

export function Command() {
  const wallboardMode =
    commandPlaneSurface.value === 'warroom'
    && route.value.params.presentation === 'wallboard'

  useEffect(() => {
    void refreshCommandPlaneCurrentSurface()
    void refreshCommandPlaneChainSummary()
    void refreshCommandPlaneHelp()
    void refreshCommandPlaneSwarm()
    void refreshCommandPlaneOrchestra()
  }, [])

  useEffect(() => {
    if (route.value.tab !== 'operations' || route.value.params.section !== 'command') return
    const requestedSurface = route.value.params.surface
    const requestedOperation = route.value.params.operation
    const workflowContext = workflowContextForRoute(route.value)
    if (isCommandSurface(requestedSurface)) {
      setCommandPlaneSurface(requestedSurface)
    }
    else if (workflowContext) {
      const suggestedSurface = commandSurfaceForContext(workflowContext)
      if (isCommandSurface(suggestedSurface)) {
        setCommandPlaneSurface(suggestedSurface)
      }
    }
    else if (!requestedSurface) {
      setCommandPlaneSurface('warroom')
    }
    if (requestedOperation) {
      focusCommandPlaneChainOperation(requestedOperation)
    }
    if (requestedSurface === 'swarm' || requestedSurface === 'warroom' || requestedSurface === 'orchestra' || commandPlaneSurface.value === 'warroom' || commandPlaneSurface.value === 'orchestra') {
      void refreshCommandPlaneSwarm()
    }
    if (requestedSurface === 'orchestra' || commandPlaneSurface.value === 'orchestra') {
      void refreshCommandPlaneOrchestra()
    }
    if (requestedSurface === 'warroom' || commandPlaneSurface.value === 'warroom') {
      void refreshOperatorSnapshot()
    }
  }, [
    route.value.tab,
    route.value.params.section,
    route.value.params.surface,
    route.value.params.operation,
    route.value.params.operation_id,
    route.value.params.run_id,
    route.value.params.source,
    route.value.params.action_type,
    route.value.params.target_type,
    route.value.params.target_id,
    route.value.params.focus_kind,
  ])

  useEffect(() => {
    let refreshTimer: number | null = null
    const scheduleRefresh = () => {
      if (refreshTimer) return
      refreshTimer = window.setTimeout(() => {
        refreshTimer = null
        void refreshCommandPlaneCurrentSurface()
        void refreshCommandPlaneChainSummary()
        if (commandPlaneSurface.value === 'swarm' || commandPlaneSurface.value === 'warroom' || commandPlaneSurface.value === 'orchestra') {
          void refreshCommandPlaneSwarm()
        }
        if (commandPlaneSurface.value === 'orchestra') {
          void refreshCommandPlaneOrchestra()
        }
        if (commandPlaneSurface.value === 'warroom') {
          void refreshOperatorSnapshot()
        }
      }, 250)
    }

    const es = new EventSource(chainEventsUrl())
    const listeners = CHAIN_SSE_EVENT_TYPES.map(type => {
      const handler = () => scheduleRefresh()
      es.addEventListener(type, handler)
      return { type, handler }
    })
    es.onerror = () => {
      scheduleRefresh()
    }

    return () => {
      listeners.forEach(({ type, handler }) => {
        es.removeEventListener(type, handler)
      })
      es.close()
      if (refreshTimer) {
        window.clearTimeout(refreshTimer)
      }
    }
  }, [])

  useEffect(() => {
    const interval = window.setInterval(() => {
      if (document.visibilityState === 'hidden') return
      const surface = commandPlaneSurface.value
      if (surface !== 'swarm' && surface !== 'warroom' && surface !== 'orchestra') return
      void refreshCommandPlaneCurrentSurface()
      void refreshCommandPlaneSwarm()
      if (surface === 'orchestra') {
        void refreshCommandPlaneOrchestra()
      }
      if (surface === 'warroom') {
        void refreshOperatorSnapshot()
      }
    }, 30000)

    return () => {
      window.clearInterval(interval)
    }
  }, [])

  return html`
    <section class="flex flex-col gap-[18px] ${wallboardMode ? 'p-4 rounded-[18px] cmd-plane-view wallboard' : ''}">
      ${wallboardMode ? null : html`
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)] flex justify-between gap-4 items-start max-[880px]:flex-col">
          <div>
            <h2 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider mb-1">지휘면</h2>
            <p class="text-[13px] text-[var(--text-muted)] leading-relaxed max-w-[62ch]">기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
          </div>
          <div class="flex gap-2.5 flex-wrap">
            <button
              class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]"
              onClick=${() => {
                void fire(() => runCommandPlaneDispatchTick())
              }}
              disabled=${actionDisabled('dispatch:tick')}
            >
              ${actionDisabled('dispatch:tick') ? '정리 중...' : 'Tick 실행'}
            </button>
            <button
              class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]"
              onClick=${() => {
                void refreshRoomTruth()
                void refreshCommandPlaneCurrentSurface()
                void refreshCommandPlaneChainSummary()
                void refreshCommandPlaneSwarm()
                if (commandPlaneSurface.value === 'warroom') {
                  void refreshOperatorSnapshot()
                }
              }}
              disabled=${commandPlaneLoading.value}
            >
              ${commandPlaneLoading.value ? '새로고침 중...' : '새로고침'}
            </button>
            <button
              class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]"
              onClick=${() => {
                setCommandPlaneSurface('warroom')
                navigate('operations', { ...surfaceRouteParams('warroom'), presentation: 'wallboard' })
              }}
            >
              Wallboard
            </button>
          </div>
        </div>
      `}

      ${commandPlaneError.value
        ? html`<${EmptyState} message=${commandPlaneError.value} compact />`
        : null}
      ${commandPlaneActionError.value
        ? html`<${EmptyState} message=${commandPlaneActionError.value} compact />`
        : null}
      ${wallboardMode ? null : html`<${RoomTruthStrip} />`}
      ${wallboardMode ? null : html`<${CommandWorkflowBanner} />`}
      ${wallboardMode || commandPlaneSurface.value === 'warroom' ? null : html`<${CommandEntryStrip} />`}
      ${wallboardMode ? null : html`<${SurfaceTabs} />`}
      <${SurfaceBody} wallboard=${wallboardMode} />
    </section>
  `
}
