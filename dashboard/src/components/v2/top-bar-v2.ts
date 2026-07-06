// MASC v2 — top bar (ported from prototype shell.jsx TopBar + AttentionIndicator).
// Emits the prototype `.v2-top` DOM (crumb · live statchip · attention ·
// schedule · Copilot). Wired to live signals: running count + attention
// aggregate (governance approvals, needs-attention keepers, dead/overflowed,
// stale connectors). The Copilot button reuses the existing dock controller.

import { html } from 'htm/preact'
import { useState, useEffect } from 'preact/hooks'
import { navigate, route } from '../../router'
import { executionLoaded, keepers, shellCounts, shellRuntimeResolution, staleKeepers } from '../../store'
import { activeKeeperName } from '../../keeper-state'
import { governanceData } from '../governance-signals'
import { toolsData } from '../tools/tool-state'
import { scheduledPendingApprovalCount } from '../tools/scheduled-automation-panel'
import { CopilotDockTopBarButton, type CopilotDockApi } from '../copilot-dock'
import { TweaksPanelToggle } from '../tweaks-panel'
import { StatusDot } from './primitives-v2'
import { surfaceLabel } from './nav-rail-v2'
import { configuredCountSourceLabel, keeperRowLooksRunning, resolveRuntimeCounts, runtimeCountSourceLabel } from '../../runtime-counts'
// Operational/safety chrome the v2 prototype omits but operators rely on
// (connection state, transport telemetry, emergency stop, error inbox, auth,
// build identity). Re-mounted into the v2 top bar so the reskin does not drop
// live operational visibility (PR #22081 review P1). These are zero-prop
// components that read their own signals.
import { ConnectionStatus, ErrorCounterBadge, BuildIdentityBadge } from '../dashboard-shell'
import { AuthStatus } from '../auth-status'
import { EmergencyStopControl } from '../emergency-stop-control'
import { TransportBeacon } from '../transport-beacon'

const DEAD_PHASES = new Set(['Overflowed', 'Crashed', 'Dead', 'Zombie'])

interface AttentionAgg {
  approvals: number
  keepers: number
  dead: number
  stale: number
  total: number
}

function computeAttention(): AttentionAgg {
  const ks = keepers.value
  const approvals = governanceData.value?.approval_queue?.length ?? 0
  const attKeepers = ks.filter((k) => k.needs_attention === true).length
  const dead = ks.filter((k) => !!k.lifecycle_phase && DEAD_PHASES.has(k.lifecycle_phase)).length
  const stale = staleKeepers.value.size
  return { approvals, keepers: attKeepers, dead, stale, total: approvals + attKeepers + dead + stale }
}

function AttentionIndicatorV2() {
  const [open, setOpen] = useState(false)
  useEffect(() => {
    if (!open) return
    const close = () => setOpen(false)
    window.addEventListener('click', close)
    return () => window.removeEventListener('click', close)
  }, [open])

  const a = computeAttention()
  if (!a.total) {
    return html`<span class="v2-statchip live" title="처리할 항목 없음">${'✓'} 정상</span>`
  }
  const rows = [
    { k: 'approvals', n: a.approvals, lbl: '승인 대기', sev: 'bad', nav: 'approvals' as const },
    { k: 'keepers', n: a.keepers, lbl: '주의 keeper', sev: 'warn', nav: 'monitoring' as const },
    { k: 'dead', n: a.dead, lbl: '죽음·넘침', sev: 'bad', nav: 'monitoring' as const },
    { k: 'stale', n: a.stale, lbl: 'stale 게이트', sev: 'warn', nav: 'connectors' as const },
  ].filter((r) => r.n > 0)
  const tone = a.approvals > 0 || a.dead > 0 ? 'bad' : 'warn'
  return html`
    <div class="attn-wrap" onClick=${(e: Event) => e.stopPropagation()}>
      <button class=${`v2-statchip attn ${tone}`} onClick=${() => setOpen((o) => !o)} title="지금 나를 필요로 하는 것">
        ${'⚑'} 주의 <b>${a.total}</b>
      </button>
      ${open
        ? html`
            <div class="attn-menu">
              <div class="attn-menu-h">지금 나를 필요로 하는 것</div>
              ${rows.map(
                (r) => html`
                  <button key=${r.k} class="attn-row" onClick=${() => { setOpen(false); navigate(r.nav) }}>
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
      ${/* 예약(schedule): pending-approval count from the scheduled-automation
          projection (loaded app-wide at boot). No count when the projection has
          not resolved — the chip stays a plain nav affordance rather than
          fabricating a status. */ ''}
      ${(() => {
        const pending = scheduledPendingApprovalCount(toolsData.value?.scheduled_automation ?? null)
        const pendingKnown = pending != null
        const pendingCount = pending ?? 0
        return html`
          <button
            class=${`v2-statchip${pendingKnown && pendingCount > 0 ? ' warn' : ''}`}
            data-schedule-pending=${pendingKnown ? pendingCount : 'unknown'}
            onClick=${() => navigate('schedule')}
            title=${pendingKnown && pendingCount > 0 ? `예약 자동화 큐 · 승인 대기 ${pendingCount}건` : '예약 자동화 큐'}
          >
            ${'◷'} 예약${pendingKnown && pendingCount > 0 ? html` <b>${pendingCount}</b>` : null}
          </button>
        `
      })()}
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
