import { html } from 'htm/preact'
import { SectionHeader } from './common/section-header'
import { CollapsibleSection } from './common/collapsible'
import { PanelCard } from './common/panel-card'
import { StatusDot } from './common/status-dot'
import {
  ContextChart,
  MetricsCharts,
  TokenTrendChart,
} from './keeper-detail-charts'
import { CtxCompositionPanel } from './keeper-detail-ctx-composition'
import { RawDataDebug } from './keeper-detail-debug'
import { KpiGrid } from './keeper-detail-kpi'
import {
  EquipmentList,
  RelationshipList,
  TraitsList,
} from './keeper-detail-lists'
import {
  InferenceTelemetryPanel,
  PromptTelemetryPanel,
} from './keeper-detail-telemetry'
import {
  KeeperLiveTruthPanel,
  KeeperSecretProjectionPanel,
  RuntimeLensSection,
  RuntimeSignals,
  TurnBudgetSection,
  KeeperNeighborhood,
} from './keeper-detail-runtime'
import {
  KeeperDetailSectionRail,
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
import { KeeperMemoryOsRecallPanel, KeeperTurnInspector } from './keeper-turn-inspector'
import { SupervisorDiagnosticsPanel } from './keeper-supervisor-diagnostics'
import { KeeperGoalHorizonsPanel } from './keeper-goal-horizons-panel'
import { KeeperPromptAssemblyPanel } from './keeper-prompt-assembly-panel'
import { KeeperRuntimeModelEditor } from './keeper-runtime-model-editor'
import { KeeperConditionsDivergent } from './keeper-conditions-divergent'
import { KeeperActivitySummary } from './keeper-detail-activity-summary'
import { FsmHub } from './fsm-hub'
import { currentDashboardActor } from '../api'
import type { Keeper } from '../types'
import type { KeeperCompositeSnapshot, KeeperRuntimeTraceResponse } from '../api/keeper'
import { KeeperRuntimeAlertStrip } from './keeper-detail-alert-strip'
import { KeeperCommsPanel, PlaygroundReposPanel } from './keeper-detail-comms'
import { KeeperClearContextDialog } from './keeper-detail-lifecycle'
import type { KeeperDetailEvidenceState } from './keeper-detail-hooks'

export interface KeeperDetailBodyProps {
  keeper: Keeper
  compositeSnapshot: KeeperCompositeSnapshot | null
  runtimeTrace: KeeperRuntimeTraceResponse | null
  compositeEvidence: KeeperDetailEvidenceState<KeeperCompositeSnapshot>
  runtimeTraceEvidence: KeeperDetailEvidenceState<KeeperRuntimeTraceResponse>
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
  compositeSnapshot,
  runtimeTrace,
  compositeEvidence,
  runtimeTraceEvidence,
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
    <div class="mx-auto flex w-full max-w-[1180px] flex-col gap-5 v2-monitoring-surface">
        <${KeeperRuntimeAlertStrip} keeper=${keeper} />
        <${KeeperDetailSectionRail} />

        <${KeeperDetailSection}
          id="keeper-comms"
          eyebrow="대화 & 세션"
          title="대화 / 세션"
          lockedOpen=${true}
          variant="primary"
        >
          <${KeeperCommsPanel} keeper=${keeper} />
          <${CollapsibleSection} title="세션 활동 로그" open=${false} mountWhenOpen=${true}>
            <${SessionTraceView} agentName=${keeper.name} isKeeper=${true} keeperStatus=${keeper.status} keeperGeneration=${keeper.generation} />
          <//>
        <//>

        <${KeeperDetailSection}
          id="keeper-memory-os-recall"
          eyebrow="메모리"
          title="Memory OS recall"
          lockedOpen=${true}
        >
          <${KeeperMemoryOsRecallPanel} keeperName=${keeper.name} />
        <//>

        <${KeeperDetailSection}
          id="keeper-summary"
          eyebrow="상태 개요"
          title="운영 상태 개요"
          defaultCollapsed=${true}
        >
      ${'' /* KeeperLiveTruthPanel (derived "Live truth / 런타임 / 현재 턴 / 최신 증거 / 차단" composite) moved to the 진단 / 운영 section as a default-closed CollapsibleSection. It is a derived synthesis on top of composite + keeper + runtime_trace + linked_state and lives below the raw-state alert-strip in information hierarchy. */}
      ${'' /* RFC-0046: 6-axis composite snapshot (KSM/KTC/KDP/KCL/KMC/breaker) — SSOT for keeper FSM state */}
      ${'' /* RFC-0046 §7 #2: share useKeeperComposite with FsmHub to dedup the /composite poll */}
      <${CollapsibleSection} title="FSM Hub (6축 상태 머신)" open=${false}>
        <${FsmHub}
          mode="detail"
          selectedName=${keeper.name}
          externalSnapshot=${compositeSnapshot}
          runtimeTrace=${runtimeTrace}
        />
      <//>
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
      <${KeeperActivitySummary} keeper=${keeper} />

      ${'' /* ── Per-turn token trend (input vs output) ── */}
      <${TokenTrendChart} keeper=${keeper} />

      ${'' /* ── CTX composition by category ── */}
      <${CtxCompositionPanel} keeper=${keeper} />

      ${'' /* ── Keeper prompt assembly provenance and stale guidance audit ── */}
      <${KeeperPromptAssemblyPanel} compact=${true} />

      ${'' /* ── Prompt fingerprint / segment telemetry ── */}
      <${PromptTelemetryPanel} keeper=${keeper} />

      ${'' /* ── Inference Telemetry (tok/s, cache, reasoning) ── */}
      <${InferenceTelemetryPanel} keeper=${keeper} />
        <//>

        <${KeeperDetailSection}
          id="keeper-runtime"
          eyebrow="런타임 진단"
          title="진단 / 운영"
          defaultCollapsed=${true}
        >
          ${'' /* ── 런타임 model 편집 (RFC-0207 persona runtime_id) — surfaced here so it is one expand away, not buried under 설정 → Keeper 설정 → 소스 ── */}
          <${KeeperRuntimeModelEditor} keeperName=${keeper.name} />
          <${KeeperToolTelemetry} keeperName=${keeper.name} />
          <${KeeperSecretProjectionPanel} projection=${compositeSnapshot?.secret_projection} />
          <${KeeperEvalQualityPanel} keeperName=${keeper.name} />
          <${CollapsibleSection} title="Live Truth (composite/runtime 합성)" open=${false}>
            <${KeeperLiveTruthPanel}
              keeper=${keeper}
              compositeSnapshot=${compositeSnapshot}
              runtimeTrace=${runtimeTrace}
              compositeEvidence=${compositeEvidence}
              runtimeTraceEvidence=${runtimeTraceEvidence}
            />
          <//>
          <${CollapsibleSection} title="Runtime Lens" open=${true}>
            <${RuntimeLensSection} trace=${runtimeTrace} />
          <//>
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
              <div class="pt-3 border-t border-[var(--color-border-divider)]">
                <${SectionHeader} size="xs" class="mb-3">턴 검사기 (컨텍스트 블록 diff)</${SectionHeader}>
                ${diagOpen ? html`<${KeeperTurnInspector} keeperName=${keeper.name} />` : null}
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

          <${KeeperGoalHorizonsPanel}
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
  `
}
