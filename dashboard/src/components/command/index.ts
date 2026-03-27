import { html } from 'htm/preact'
import { CARD_STANDARD } from '../common/card'
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
import { DetailLoadingState } from './guided-panel'
import { OrchestraSurface } from './orchestra'
import { SwarmSurface } from './swarm'
import { ChainsSurface, OperationsSurface } from './operations'
import { ControlSurface } from './control'
import { WarroomGuideCallout } from './warroom-guide-callout'

function SurfaceTabs() {
  return html`
    <div class="cmd-surface-tabs flex-col gap-3">
      ${COMMAND_SURFACE_GROUPS.map(group => html`
        <div class="flex flex-col gap-1.5" key=${group.id}>
          <span class="text-[11px] font-semibold text-[var(--white-40)] uppercase tracking-[0.04em] pl-1">${group.label}</span>
          <div class="flex flex-wrap gap-2">
            ${COMMAND_SURFACE_META
              .filter(surface => surface.group === group.id)
              .map(surface => html`
                <button type="button"
                  class="border border-[var(--white-12)] bg-[var(--white-4)] text-[var(--white-72)] p-[8px_14px] capitalize rounded-full cmd-surface-tab ${commandPlaneSurface.value === surface.id ? 'active' : ''}"
                  onClick=${() => {
                    setCommandPlaneSurface(surface.id)
                    navigate('command', surfaceRouteParams(surface.id))
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

function SurfaceBody() {
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
    case 'control':
      return html`<${ControlSurface} />`
    case 'operations':
    default:
      return html`<${OperationsSurface} />`
  }
}

export function Command() {
  useEffect(() => {
    void refreshCommandPlaneHelp()
  }, [])

  useEffect(() => {
    if (route.value.tab !== 'command' || route.value.params.section !== 'warroom') return
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
      setCommandPlaneSurface('operations')
    }
    if (requestedOperation) {
      focusCommandPlaneChainOperation(requestedOperation)
    }
    if (requestedSurface === 'swarm' || requestedSurface === 'orchestra' || commandPlaneSurface.value === 'orchestra') {
      void refreshCommandPlaneSwarm(undefined, undefined, { force: true })
    }
    if (requestedSurface === 'orchestra' || commandPlaneSurface.value === 'orchestra') {
      void refreshCommandPlaneOrchestra(undefined, undefined, { force: true })
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
        void refreshCommandPlaneCurrentSurface({ force: true })
        void refreshCommandPlaneChainSummary({ force: true })
        if (commandPlaneSurface.value === 'swarm' || commandPlaneSurface.value === 'orchestra') {
          void refreshCommandPlaneSwarm(undefined, undefined, { force: true })
        }
        if (commandPlaneSurface.value === 'orchestra') {
          void refreshCommandPlaneOrchestra(undefined, undefined, { force: true })
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
      if (surface !== 'swarm' && surface !== 'orchestra') return
      void refreshCommandPlaneCurrentSurface()
      void refreshCommandPlaneSwarm()
      if (surface === 'orchestra') {
        void refreshCommandPlaneOrchestra()
      }
    }, 30000)

    return () => {
      window.clearInterval(interval)
    }
  }, [])

  return html`
    <section class="flex flex-col gap-[18px]">
      <div class="${CARD_STANDARD} flex justify-end gap-4 items-center flex-wrap">
        <div class="flex gap-3 flex-wrap">
          <button type="button"
            class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]"
            onClick=${() => {
              void fire(() => runCommandPlaneDispatchTick())
            }}
            disabled=${actionDisabled('dispatch:tick')}
          >
            ${actionDisabled('dispatch:tick') ? '정리 중...' : 'Tick 실행'}
          </button>
          <button type="button"
            class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]"
            onClick=${() => {
              void refreshRoomTruth({ force: true })
              void refreshCommandPlaneCurrentSurface({ force: true })
              void refreshCommandPlaneChainSummary({ force: true })
              void refreshCommandPlaneSwarm(undefined, undefined, { force: true })
            }}
            disabled=${commandPlaneLoading.value}
          >
            ${commandPlaneLoading.value ? '새로고침 중...' : '새로고침'}
          </button>
        </div>
      </div>

      ${commandPlaneError.value
        ? html`<${EmptyState} message=${commandPlaneError.value} compact />`
        : null}
      ${commandPlaneActionError.value
        ? html`<${EmptyState} message=${commandPlaneActionError.value} compact />`
        : null}
      <${RoomTruthStrip} />
      <${WarroomGuideCallout} />
      <${SurfaceTabs} />
      <${SurfaceBody} />
    </section>
  `
}
