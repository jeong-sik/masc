import { html } from 'htm/preact'
import { TimeAgo } from './common/time-ago'
import { SectionHeader } from './common/section-header'
import { CollapsibleSection } from './common/collapsible'
import { PanelCard } from './common/panel-card'
import { StatusDot } from './common/status-dot'
import {
  ContextChart,
  CtxCompositionPanel,
  EquipmentList,
  InferenceTelemetryPanel,
  KpiGrid,
  MetricsCharts,
  PromptTelemetryPanel,
  RawDataDebug,
  RelationshipList,
  TokenTrendChart,
  TraitsList,
} from './keeper-detail-panels'
import {
  RuntimeSignals,
  TurnBudgetSection,
  KeeperNeighborhood,
} from './keeper-detail-runtime'
import {
  KeeperDetailOverviewSidebar,
  KeeperDetailSection,
} from './keeper-detail-shell'
import {
  GenerationLineagePanel,
  KeeperCheckpointPanel,
} from './keeper-detail-history'
import {
  KeeperDiagnosticSummary,
  KeeperRuntimeActions,
} from './keeper-shared'
import { KeeperStateDiagramPanel } from './keeper-state-diagram'
import { KeeperMemoryTierPanel } from './keeper-memory-tier-panel'
import { AgentJournalStream } from './agent-detail-journal'
import { SessionTraceView } from './session-trace/session-trace-view'
import { KeeperToolTelemetry } from './keeper-tool-telemetry'
import { KeeperEvalQualityPanel } from './keeper-eval-quality'
import { KeeperToolCallInspector } from './keeper-tool-call-inspector'
import { SupervisorDiagnosticsPanel } from './keeper-supervisor-diagnostics'
import { KeeperBDIPanel } from './keeper-bdi-panel'
import { KeeperConfigPanel } from './keeper-config-panel'
import { KeeperConditionsDivergent } from './keeper-conditions-divergent'
import { FsmHub } from './fsm-hub'
import { currentDashboardActor } from '../api'
import type { Keeper } from '../types'
import type { KeeperCompositeSnapshot } from '../api/keeper'
import type { keeperActivityDisplay } from '../lib/keeper-runtime-display'
import { KeeperRuntimeAlertStrip } from './keeper-detail-alert-strip'
import { KeeperCommsPanel, PlaygroundReposPanel } from './keeper-detail-comms'
import { KeeperClearContextDialog } from './keeper-detail-lifecycle'

export interface KeeperDetailBodyProps {
  keeper: Keeper
  effectiveStatus: string
  contextRatioPct: string
  effectiveModelLabel: string
  effectiveModel: string
  activityDisplay: ReturnType<typeof keeperActivityDisplay>
  compositeSnapshot: KeeperCompositeSnapshot | null
  diagOpen: boolean
  onDiagToggle: (open: boolean) => void
  checkpointRefreshToken: number
  clearDialogOpen: boolean
  clearPending: boolean
  clearReason: string
  preserveSystemPrompt: boolean
  onClearClose: () => void
  onClearReasonInput: (reason: string) => void
  onPreserveToggle: (preserve: boolean) => void
  onClearSubmit: () => void
  onSocialSweep: () => void
}

export function KeeperDetailBody({
  keeper,
  effectiveStatus,
  contextRatioPct,
  effectiveModelLabel,
  effectiveModel,
  activityDisplay,
  compositeSnapshot,
  diagOpen,
  onDiagToggle,
  checkpointRefreshToken,
  clearDialogOpen,
  clearPending,
  clearReason,
  preserveSystemPrompt,
  onClearClose,
  onClearReasonInput,
  onPreserveToggle,
  onClearSubmit,
  onSocialSweep,
}: KeeperDetailBodyProps) {
  return html`
    <div class="grid gap-5 xl:grid-cols-[280px_minmax(0,1fr)]">
      <${KeeperDetailOverviewSidebar}
        effectiveStatus=${effectiveStatus}
        contextRatioPct=${contextRatioPct}
        effectiveModelLabel=${effectiveModelLabel}
        effectiveModel=${effectiveModel}
        activity=${activityDisplay}
      />

      <div class="order-1 xl:order-2 flex flex-col gap-5">
        <${KeeperRuntimeAlertStrip} keeper=${keeper} />

        <${KeeperDetailSection}
          id="keeper-summary"
          eyebrow="상태 개요"
          title="운영 상태 개요"
        >
      ${'' /* RFC-0046: 6-axis composite snapshot (KSM/KTC/KDP/KCL/KMC/breaker) — SSOT for keeper FSM state */}
      ${'' /* RFC-0046 §7 #2: share useKeeperComposite with FsmHub to dedup the /composite poll */}
      <${FsmHub}
        mode="detail"
        selectedName=${keeper.name}
        externalSnapshot=${compositeSnapshot}
      />
      <${CollapsibleSection} title="Phase State Machine">
        <${KeeperStateDiagramPanel} keeperName=${keeper.name} snapshot=${compositeSnapshot} />
      <//>

      <${CollapsibleSection} title="Memory Tier & Compaction">
        <${KeeperMemoryTierPanel} keeperName=${keeper.name} snapshot=${compositeSnapshot} />
      <//>

      ${'' /* ── Divergent conditions (amber banner; renders only when phase lags observed signals) ── */}
      <${KeeperConditionsDivergent} keeper=${keeper} />

      ${'' /* ── KPIs ── */}
      <${KpiGrid} keeper=${keeper} />

      ${'' /* ── Context chart (sparkline only — single-point is covered by KpiGrid) ── */}
      ${(keeper.metrics_series ?? []).length >= 2 ? html`<${ContextChart} keeper=${keeper} />` : null}

      ${'' /* ── Latency / Cost / Model charts ── */}
      <${MetricsCharts} keeper=${keeper} />

      ${'' /* ── Runtime activity summary (promoted from profile) ── */}
      ${keeper.last_heartbeat || keeper.last_speech_act || keeper.recent_output_preview || keeper.memory_recent_note || (keeper.k2k_count ?? 0) > 0
        ? html`
          <div class="flex flex-wrap items-start gap-3 px-1">
            ${keeper.last_heartbeat
              ? html`<span class="inline-flex items-center gap-1.5 text-2xs text-[var(--color-fg-muted)] px-2.5 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
                  하트비트 <${TimeAgo} timestamp=${keeper.last_heartbeat} />
                </span>`
              : null}
            ${keeper.last_speech_act
              ? html`<span class="inline-flex items-center gap-1.5 text-2xs text-[var(--color-fg-muted)] px-2.5 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
                  최근 <span class="font-mono text-[var(--color-fg-primary)]">${keeper.last_speech_act}</span>
                </span>`
              : null}
            ${keeper.social_model_recognized === false
              ? html`<span class="inline-flex items-center gap-1.5 text-2xs text-[var(--color-status-warn)] px-2.5 py-1 rounded-[var(--r-1)] border border-[var(--warn-24)] bg-[var(--warn-8)]">
                  대화 모델
                  ${keeper.configured_social_model
                    ? html`<span class="font-mono text-[var(--color-fg-primary)]">${keeper.configured_social_model}</span>`
                    : null}
                  ${keeper.configured_social_model && keeper.social_model_fallback
                    ? html`<span>→</span>`
                    : null}
                  ${keeper.social_model_fallback
                    ? html`<span class="font-mono text-[var(--color-fg-primary)]">${keeper.social_model_fallback}</span>`
                    : null}
                </span>`
              : null}
            ${(keeper.k2k_count ?? 0) > 0
              ? html`<span class="inline-flex items-center gap-1 text-2xs px-2.5 py-1 rounded-[var(--r-1)] bg-[var(--info-soft)] border border-[var(--info-border)] text-[var(--color-fg-muted)]">
                  K2K <span class="font-mono font-medium text-[var(--info-fg)]">${keeper.k2k_count}</span>
                </span>`
              : null}
            ${keeper.memory_recent_note
              ? html`<span class="text-2xs text-[var(--color-fg-muted)] px-2.5 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] truncate max-w-90" title=${keeper.memory_recent_note}>${keeper.memory_recent_note}</span>`
              : null}
          </div>
          ${keeper.recent_output_preview
            ? html`<div class="py-2 px-3 rounded-[var(--r-1)] bg-[var(--accent-6)] border border-[var(--accent-12)] text-xs text-[var(--color-fg-primary)] leading-relaxed">
                <div class="line-clamp-2">${keeper.recent_output_preview}</div>
              </div>`
            : null}
        `
        : null}

      ${'' /* ── Per-turn token trend (input vs output) ── */}
      <${TokenTrendChart} keeper=${keeper} />

      ${'' /* ── CTX composition by category ── */}
      <${CtxCompositionPanel} keeper=${keeper} />

      ${'' /* ── Prompt fingerprint / segment telemetry ── */}
      <${PromptTelemetryPanel} keeper=${keeper} />

      ${'' /* ── Inference Telemetry (tok/s, cache, reasoning) ── */}
      <${InferenceTelemetryPanel} keeper=${keeper} />
        <//>

        <${KeeperDetailSection}
          id="keeper-comms"
          eyebrow="대화 & 세션"
          title="대화 / 활동 흐름"
          defaultCollapsed=${true}
        >
          <${KeeperCommsPanel} keeper=${keeper} />
          <${PanelCard} title="세션 활동 로그">
            <${SessionTraceView} agentName=${keeper.name} isKeeper=${true} keeperStatus=${keeper.status} keeperGeneration=${keeper.generation} />
          <//>
        <//>

        <${KeeperDetailSection}
          id="keeper-runtime"
          eyebrow="런타임 진단"
          title="진단 / 운영"
          defaultCollapsed=${true}
        >
          <${KeeperToolTelemetry} keeperName=${keeper.name} />
          <${KeeperEvalQualityPanel} keeperName=${keeper.name} />
          <${CollapsibleSection}
            title="런타임 진단"
            open=${diagOpen}
            onToggle=${(open: boolean) => onDiagToggle(open)}
          >
            <div class="flex flex-col gap-3">
              <${SupervisorDiagnosticsPanel} keeper=${keeper} />
              <${KeeperDiagnosticSummary} keeper=${keeper} />
              <${KeeperRuntimeActions}
                actor=${currentDashboardActor()}
                keeper=${keeper}
                onSocialSweep=${onSocialSweep}
              />
              <div class="pt-3 border-t border-[var(--color-border-divider)]">
                <${SectionHeader} size="xs" class="mb-3">호출 검사기</${SectionHeader}>
                ${diagOpen ? html`<${KeeperToolCallInspector} keeperName=${keeper.name} />` : null}
              </div>
            </div>
          <//>
          <${CollapsibleSection} title="품질 시그널 (고급 지표)">
            <${RuntimeSignals} keeper=${keeper} />
          <//>
        <//>

        <${KeeperDetailSection}
          id="keeper-identity"
          eyebrow="신원 & 계보"
          title="정체성 / 세대"
          defaultCollapsed=${true}
        >
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <${PanelCard} title="프로필">
          <${TraitsList} traits=${keeper.traits ?? []} label="특성" />
          <${TraitsList} traits=${keeper.interests ?? []} label="관심사" />
          ${keeper.primaryValue
            ? html`<div class="flex items-center gap-2 mt-3 text-xs text-[var(--color-fg-muted)]">
                <span class="text-[var(--color-fg-muted)]">핵심 가치:</span>
                <span class="font-medium text-[var(--color-status-ok)]">${keeper.primaryValue}</span>
              </div>`
            : null}
          ${keeper.skill_primary
            ? html`<div class="flex items-center gap-2 mt-2 text-xs text-[var(--color-fg-muted)]">
                <span>스킬 경로:</span>
                <span class="font-medium text-[var(--cyan)]">${keeper.skill_primary}</span>
              </div>`
            : null}
          ${keeper.skill_reason
            ? html`<div class="text-2xs text-[var(--color-fg-muted)] mt-1 leading-relaxed">${keeper.skill_reason}</div>`
            : null}

          <${KeeperBDIPanel}
            will=${keeper.will}
            needs=${keeper.needs}
            desires=${keeper.desires}
            short_goal=${keeper.short_goal}
            mid_goal=${keeper.mid_goal}
            long_goal=${keeper.long_goal}
            goal_horizons=${keeper.goal_horizons}
          />
            <//>

          ${keeper.inventory && keeper.inventory.length > 0
            ? html`
              <${PanelCard} title="장비 (${keeper.inventory.length})">
                <${EquipmentList} items=${keeper.inventory} />
              <//>
            `
            : null}

          ${keeper.relationships && Object.keys(keeper.relationships).length > 0
            ? html`
              <${PanelCard} title="관계 (${Object.keys(keeper.relationships).length})">
                <${RelationshipList} rels=${keeper.relationships} />
              <//>
            `
            : null}

          <${GenerationLineagePanel} keeperName=${keeper.name} />
            </div>

          <${CollapsibleSection} title="Checkpoint & Snapshots">
            <div class="mt-4">
              <${KeeperCheckpointPanel}
                keeperName=${keeper.name}
                refreshToken=${checkpointRefreshToken}
              />
            </div>
          <//>
        <//>

        <${KeeperDetailSection}
          id="keeper-config"
          eyebrow="설정"
          title="설정 / 작업 방식"
          defaultCollapsed=${true}
        >
          <${TurnBudgetSection} keeper=${keeper} />
          <${CollapsibleSection} title="허용 도구">
            <div class="mt-3">
              <${KeeperNeighborhood} keeper=${keeper} />
            </div>
          <//>
          <${PlaygroundReposPanel} keeperName=${keeper.name} />
          <${CollapsibleSection} title="Keeper 설정">
            <div class="mt-4">
              <${KeeperConfigPanel} keeperName=${keeper.name} />
            </div>
          <//>
        <//>

        <${KeeperDetailSection}
          id="keeper-debug"
          eyebrow="디버그"
          title="디버그"
          defaultCollapsed=${true}
        >
          <details class="mt-0">
        <summary class="cursor-pointer py-3 px-4 text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)] list-none select-none rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] hover:bg-[var(--color-bg-hover)] transition-colors flex items-center gap-2">
          <${StatusDot} size="xs" class="bg-[var(--color-fg-disabled)]" />
          디버그
        </summary>
        <div class="mt-2 flex flex-col gap-4">
          <div class="p-5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] backdrop-blur-sm">
            <${SectionHeader} size="xs" class="mb-3">저널</${SectionHeader}>
            <${AgentJournalStream} agentName=${keeper.name} />
          </div>
          <div class="p-5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] backdrop-blur-sm">
            <${SectionHeader} size="xs" class="mb-3">원시 데이터</${SectionHeader}>
            <${RawDataDebug} keeper=${keeper} />
          </div>
        </div>
      </details>
        <//>

      <${KeeperClearContextDialog}
        keeperName=${keeper.name}
        open=${clearDialogOpen}
        pending=${clearPending}
        reason=${clearReason}
        preserveSystemPrompt=${preserveSystemPrompt}
        onClose=${onClearClose}
        onReasonInput=${onClearReasonInput}
        onPreserveToggle=${onPreserveToggle}
        onSubmit=${onClearSubmit}
      />
      </div>
    </div>
  `
}
