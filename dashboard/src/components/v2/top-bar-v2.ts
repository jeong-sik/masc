// MASC v2 — top bar (ported from prototype shell.jsx TopBar + AttentionIndicator).
// Emits the prototype `.v2-top` DOM (crumb · live statchip · attention ·
// schedule · Copilot). Wired to live signals: running count + attention
// aggregate (Gate approvals, needs-attention keepers, dead/overflowed,
// stale connectors). The Copilot button reuses the existing dock controller.

import { html } from 'htm/preact'
import { useState, useEffect } from 'preact/hooks'
import { navigate, route } from '../../router'
import { executionLoaded, keepers, shellCounts, shellRuntimeResolution, staleKeepers } from '../../store'
import { activeKeeperName } from '../../keeper-state'
import { gateData } from '../gate-signals'
import { CopilotDockTopBarButton, type CopilotDockApi } from '../copilot-dock'
import { TweaksPanelToggle } from '../tweaks-panel'
import { StatusDot } from './primitives-v2'
import { surfaceLabel } from './nav-rail-v2'
import { configuredCountSourceLabel, keeperRowLooksRunning, resolveRuntimeCounts, runtimeCountSourceLabel } from '../../runtime-counts'
import {
  projectDashboardCompositeHealth,
  type DashboardCompositeHealthVerdict,
} from '../../lib/dashboard-composite-health'
// Operational/safety chrome the v2 prototype omits but operators rely on
// (connection state, transport telemetry, emergency stop, error inbox, auth,
// build identity). Re-mounted into the v2 top bar so the reskin does not drop
// live operational visibility (PR #22081 review P1). These are zero-prop
// components that read their own signals.
import { ConnectionStatus, ErrorCounterBadge, BuildIdentityBadge } from '../dashboard-shell'
import { AuthStatus } from '../auth-status'
import { EmergencyStopControl } from '../emergency-stop-control'
import { TransportBeacon } from '../transport-beacon'
import {
  dashboardFullHealth,
  subscribeDashboardFullHealthRefresh,
} from '../dashboard-full-health-state'

const DEAD_PHASES = new Set(['Overflowed', 'Crashed', 'Dead'])

interface AttentionAgg {
  approvals: number | null
  approvalQueueState: NonNullable<typeof gateData.value>['approval_queue_state'] | null
  keepers: number
  dead: number
  stale: number
  health: DashboardCompositeHealthVerdict
  total: number
}

function computeAttention(): AttentionAgg {
  const ks = keepers.value
  const approvalQueueState = gateData.value?.approval_queue_state ?? null
  const approvals =
    approvalQueueState?.state === 'ready'
      ? gateData.value?.approval_queue?.length ?? null
      : null
  const attKeepers = ks.filter((k) => k.needs_attention === true).length
  const dead = ks.filter((k) => !!k.lifecycle_phase && DEAD_PHASES.has(k.lifecycle_phase)).length
  const stale = staleKeepers.value.size
  const health = projectDashboardCompositeHealth(dashboardFullHealth.value)
  return {
    approvals,
    approvalQueueState,
    keepers: attKeepers,
    dead,
    stale,
    health,
    total: (approvals ?? 0) + attKeepers + dead + stale + health.issueCount,
  }
}

interface AttentionRow {
  k: string
  n: number | string
  lbl: string
  detail?: string
  sev: 'bad' | 'warn'
  nav: 'approvals' | 'monitoring' | 'connectors'
  params?: Record<string, string>
}

export function AttentionIndicatorV2() {
  const [open, setOpen] = useState(false)
  useEffect(() => subscribeDashboardFullHealthRefresh(), [])
  useEffect(() => {
    if (!open) return
    const close = () => setOpen(false)
    window.addEventListener('click', close)
    return () => window.removeEventListener('click', close)
  }, [open])

  const a = computeAttention()
  if (a.approvalQueueState && a.approvalQueueState.state !== 'ready') {
    const state = a.approvalQueueState
    return html`
      <button
        class=${`v2-statchip attn ${state.severity}`}
        onClick=${() => navigate('approvals')}
        title=${state.operator_detail}
      >${state.icon} ${state.title}</button>
    `
  }
  if (a.approvalQueueState?.state !== 'ready' || a.approvals === null) {
    return html`
      <button
        class="v2-statchip attn warn"
        onClick=${() => navigate('approvals')}
        title="Gate queue state has not loaded"
      >? 승인 큐 확인 필요</button>
    `
  }
  if (!a.total && a.health.state === 'healthy') {
    return html`<span class="v2-statchip live" title="처리할 항목 없음">${'✓'} 정상</span>`
  }
  const rows: AttentionRow[] = []
  if (a.approvals !== null && a.approvals > 0) rows.push({ k: 'approvals', n: a.approvals, lbl: '승인 대기', sev: 'bad', nav: 'approvals' })
  if (a.keepers > 0) rows.push({ k: 'keepers', n: a.keepers, lbl: '주의 keeper', sev: 'warn', nav: 'monitoring' })
  if (a.dead > 0) rows.push({ k: 'dead', n: a.dead, lbl: '죽음·넘침', sev: 'bad', nav: 'monitoring' })
  if (a.stale > 0) rows.push({ k: 'stale', n: a.stale, lbl: 'stale 게이트', sev: 'warn', nav: 'connectors' })
  if (a.health.state === 'attention') {
    rows.push(...a.health.issues.map(issue => ({
      k: issue.kind,
      n: 1,
      lbl: issue.label,
      detail: issue.detail,
      sev: issue.severity,
      nav: 'monitoring' as const,
      params: { section: 'fleet-health' },
    })))
  } else if (a.health.state === 'unavailable') {
    rows.push({
      k: 'composite-health-unavailable',
      n: '—',
      lbl: 'Fleet health 미연결',
      detail: 'Backend composite fleet health verdict has not loaded.',
      sev: 'warn',
      nav: 'monitoring',
      params: { section: 'fleet-health' },
    })
  }
  const tone = a.approvals > 0 || a.dead > 0 || (a.health.state === 'attention' && a.health.severity === 'bad')
    ? 'bad'
    : 'warn'
  const totalLabel = a.health.state === 'unavailable'
    ? a.total > 0 ? `${a.total}+?` : '?'
    : String(a.total)
  return html`
    <div class="attn-wrap" onClick=${(e: Event) => e.stopPropagation()}>
      <button class=${`v2-statchip attn ${tone}`} onClick=${() => setOpen((o) => !o)} title="지금 나를 필요로 하는 것">
        ${'⚑'} 주의 <b>${totalLabel}</b>
      </button>
      ${open
        ? html`
            <div class="attn-menu">
              <div class="attn-menu-h">지금 나를 필요로 하는 것</div>
              ${rows.map(
                (r) => html`
                  <button
                    key=${r.k}
                    class="attn-row"
                    title=${r.detail}
                    onClick=${() => { setOpen(false); navigate(r.nav, r.params) }}
                  >
                    <span class=${`dot2 ${r.sev}`}></span>
                    <span class="attn-row-lbl">${r.lbl}</span>
                    <span class="attn-row-n mono">${r.n}</span>
                  </button>
                `,
              )}
            </div>
          `
        : null}
    </div>
  `
}

export function TopBarV2({ dock }: { dock: CopilotDockApi }) {
  const tab = route.value.tab
  const fallbackRunningKeepers = keepers.value.filter((keeper) => keeperRowLooksRunning({
    status: keeper.status,
    phase: keeper.lifecycle_phase ?? keeper.phase,
    pipeline_stage: keeper.pipeline_stage,
    paused: keeper.paused,
    keepalive_running: keeper.keepalive_running,
  })).length
  const runtimeCounts = resolveRuntimeCounts({
    executionLoaded: executionLoaded.value,
    agentsCount: shellCounts.value?.agents ?? 0,
    keepersCount: shellCounts.value?.keepers ?? fallbackRunningKeepers,
    keeperRowsCount: keepers.value.length,
    shellCounts: shellCounts.value,
    shellConfiguredKeepers: shellCounts.value?.configured_keepers,
    runtimeFleetSafety: shellRuntimeResolution.value?.fleet_safety ?? null,
    runtimeHealthGeneratedAt: shellRuntimeResolution.value?.generated_at ?? null,
  })
  const running = runtimeCounts.live.keepers
  const countTitle = [
    `runtime count: ${runtimeCountSourceLabel(runtimeCounts.source)}`,
    `running=${runtimeCounts.live.keepers}`,
    `paused=${runtimeCounts.live.pausedKeepers}`,
    runtimeCounts.source === 'runtime-health'
      ? 'offline=0 (not derived from execution rows)'
      : `offline=${runtimeCounts.live.offlineKeepers}`,
    `configured=${runtimeCounts.configured.keepers} (${configuredCountSourceLabel(runtimeCounts.configured.source)})`,
  ].join('; ')
  const crumbKeeper = tab === 'keepers' ? route.value.params.keeper?.trim() || activeKeeperName.value || '' : ''
  return html`
    <div class="v2-top">
      <div class="crumb">
        <span class=${tab === 'keepers' && crumbKeeper ? '' : 'on'}>${surfaceLabel(tab)}</span>
        ${tab === 'keepers' && crumbKeeper
          ? html`<span>/</span><span class="on">${crumbKeeper}</span>`
          : null}
      </div>
      <div class="v2-top-spacer"></div>
      <span class="v2-statchip live" title=${countTitle}>
        <${StatusDot} status="run" pulse=${true} />${running} 실행 중
      </span>
      <${AttentionIndicatorV2} />
      <button class="v2-statchip" onClick=${() => navigate('schedule')} title="예약 자동화 큐">
        ${'◷'} 예약
      </button>
      ${/* Operational/safety status cluster (review P1: keep operator chrome). */ ''}
      <div class="v2-top-ops">
        <${ConnectionStatus} />
        <${TransportBeacon} />
        <${EmergencyStopControl} />
        <${ErrorCounterBadge} />
        <${AuthStatus} />
      </div>
      <${CopilotDockTopBarButton} dock=${dock} />
      <${BuildIdentityBadge} />
      <${TweaksPanelToggle} />
    </div>
  `
}
