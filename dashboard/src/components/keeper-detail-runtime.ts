// Keeper runtime signals, neighborhood, and tool audit panels.
// Redesigned: consistent signal row styling with inline Tailwind,
// clean tool chip badges, proper section spacing.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { ActionButton } from './common/button'
import { CollapsibleSection } from './common/collapsible'
import { DistributionBars, type DistributionItem } from './common/distribution-bars'
import { TextInput } from './common/input'
import { TimeAgo } from './common/time-ago'
import { SectionHeader } from './common/section-header'
import { StatusChip, type StatusChipTone } from './common/status-chip'
import { toolCategory } from './tool-call-shared'
import type { Keeper } from '../types'
import { serverStatus } from '../store'
import { operatorSnapshot } from '../operator-store'
import {
  allowlistEmptyState,
  auditMetadataState,
  linkedRuntimeState,
  observedToolsEmptyState,
  openToolsInventory,
  toolAuditStateLabel,
} from './common/tool-audit'
import {
  resolveKeeperMissionBrief,
  resolveKeeperObservedToolAudit,
  resolveKeeperToolPolicy,
} from './keeper-detail-source'
import {
  loadKeeperConfig,
  peekKeeperConfigLoadStatus,
  peekLoadedKeeperConfig,
} from './keeper-config-panel'

const DEFAULT_ALLOWLIST_PREVIEW_LIMIT = 12

// ── Utility functions ────────────────────────────────────

export function resolveKeeperCurrentTaskLabel(
  keeper: Keeper | null | undefined,
): string {
  const runtimeState = linkedRuntimeState(keeper)
  if (!keeper) return 'unlinked'
  if (runtimeState === 'offline') return 'offline'
  if (!keeper.agent) return 'not_collected'
  if (typeof keeper.agent.current_task === 'string' && keeper.agent.current_task.trim() !== '') {
    return keeper.agent.current_task
  }
  return 'unassigned'
}

// ── Shared row component ─────────────────────────────────

function SignalRow({ label, value }: { label: string; value: string | number }) {
  return html`
    <div class="flex items-center justify-between py-2 px-3 rounded-[var(--r-1)] bg-[var(--color-bg-surface)]">
      <span class="text-xs text-[var(--color-fg-muted)]">${label}</span>
      <span class="text-xs font-medium text-[var(--color-fg-secondary)]">${value}</span>
    </div>
  `
}

// ── Tool chip badge ──────────────────────────────────────

function ToolChip({ name }: { name: string }) {
  const cat = toolCategory(name)
  return html`
    <${ActionButton}
      variant="primary"
      size="sm"
      class="!rounded-[var(--r-0)] !py-0.5 !text-3xs !text-[var(--color-accent-fg)] inline-flex items-center gap-1"
      title=${`${cat.label}: ${name}`}
      ariaLabel=${`${cat.label}: ${name}`}
      onClick=${() => openToolsInventory(name)}
    >
      <span class="font-mono font-bold ${cat.color}">${cat.icon}</span>
      <span>${name}</span>
    <//>
  `
}

export function resolveAllowlistPreview(
  tools: string[],
  previewLimit = DEFAULT_ALLOWLIST_PREVIEW_LIMIT,
): { visibleTools: string[]; hiddenCount: number } {
  const normalizedLimit = Math.max(0, previewLimit)
  const visibleTools = tools.slice(0, normalizedLimit)
  return {
    visibleTools,
    hiddenCount: Math.max(0, tools.length - visibleTools.length),
  }
}

export function AllowlistPreview({
  tools,
  emptyLabel,
  previewLimit = DEFAULT_ALLOWLIST_PREVIEW_LIMIT,
}: {
  tools: string[]
  emptyLabel: string
  previewLimit?: number
}) {
  const [expanded, setExpanded] = useState(false)
  const firstTool = tools[0] ?? null
  const lastTool = tools.length > 0 ? tools[tools.length - 1] : null

  useEffect(() => {
    setExpanded(false)
  }, [tools.length, firstTool, lastTool, previewLimit])

  if (tools.length === 0) {
    return html`<span class="text-2xs text-[var(--color-fg-muted)] italic">${emptyLabel}</span>`
  }

  const { visibleTools, hiddenCount } = expanded
    ? { visibleTools: tools, hiddenCount: 0 }
    : resolveAllowlistPreview(tools, previewLimit)

  return html`
    <div class="flex flex-col gap-2">
      <div class="flex flex-wrap gap-1.5">
        ${visibleTools.map(tool => html`<${ToolChip} name=${tool} />`)}
        ${!expanded && hiddenCount > 0
          ? html`
              <span class="inline-flex items-center py-0.5 px-2 rounded-[var(--r-0)] text-3xs font-medium border border-dashed border-[var(--color-border-default)] text-[var(--color-fg-muted)]">
                +${hiddenCount}
              </span>
            `
          : null}
      </div>
      ${tools.length > previewLimit
        ? html`
            <button type="button"
              class="self-start text-3xs text-[var(--color-fg-muted)] hover:text-[var(--color-fg-primary)] cursor-pointer transition-colors"
              aria-expanded=${expanded}
              aria-label=${expanded ? '허용된 도구 접기' : `허용된 도구 나머지 ${hiddenCount}개 보기`}
              onClick=${() => setExpanded(value => !value)}
            >
              ${expanded ? '접기' : `나머지 ${hiddenCount}개 보기`}
            </button>
          `
        : null}
    </div>
  `
}

// ── Tool list section ────────────────────────────────────

function ToolSection({ title, description, tools, fallback }: { title: string; description?: string; tools: string[]; fallback: string }) {
  return html`
    <div class="flex flex-col gap-1.5 mt-3">
      <${SectionHeader} size="xs">${title}</${SectionHeader}>
      ${description ? html`<span class="text-2xs text-[var(--color-fg-muted)] leading-snug">${description}</span>` : null}
      <div class="flex flex-wrap gap-1.5">
        ${tools.length > 0
          ? tools.map(tool => html`<${ToolChip} name=${tool} />`)
          : html`<span class="text-2xs text-[var(--color-fg-muted)] italic">${fallback}</span>`}
      </div>
    </div>
  `
}

// ── Turn Budget ──────────────────────────────────────────

function hasTurnBudgetDivergence(keeper: Keeper): boolean {
  const b = keeper.turn_budget
  if (!b) return false
  return (
    b.reactive.source === 'override' ||
    b.reactive.source === 'override_invalid' ||
    b.scheduled_autonomous.source === 'override' ||
    b.scheduled_autonomous.source === 'override_invalid'
  )
}

export type BudgetSource = 'override' | 'env' | 'override_invalid'

interface BudgetSlot {
  value: number
  source: BudgetSource
  env_default: number
  env_var: string
  raw_override: number | null
}

export function budgetSourceTone(source: BudgetSource): StatusChipTone {
  switch (source) {
    case 'override_invalid':
      return 'bad'
    case 'override':
      return 'warn'
    case 'env':
    default:
      return 'neutral'
  }
}

export function budgetSourceLabel(source: BudgetSource): string {
  switch (source) {
    case 'override_invalid':
      return 'invalid'
    case 'override':
      return 'override'
    case 'env':
    default:
      return 'env'
  }
}

export function BudgetSourceBadge({ source, children }: { source: BudgetSource; children?: unknown }) {
  const weight = source === 'env' ? 'font-medium' : 'font-semibold'
  return html`<${StatusChip} tone=${budgetSourceTone(source)} uppercase=${true} class=${weight}>${children ?? budgetSourceLabel(source)}</${StatusChip}>`
}

function buildBudgetTooltip(slot: BudgetSlot, manifest: string | null, clamp: { min: number; max: number }): string {
  const lines: string[] = []
  if (slot.source === 'override') {
    lines.push(`Source: TOML override`)
    if (manifest) lines.push(`File:   ${manifest}`)
    lines.push(`Value:  ${slot.value}  (env default was ${slot.env_default})`)
  } else if (slot.source === 'override_invalid') {
    lines.push(`Source: env default (override REJECTED)`)
    if (manifest) lines.push(`File:   ${manifest}`)
    if (slot.raw_override != null) {
      lines.push(`Raw:    ${slot.raw_override}  — out of range [${clamp.min}, ${clamp.max}]`)
    }
    lines.push(`Value:  ${slot.value}  (fell back to env default)`)
  } else {
    lines.push(`Source: env default`)
    lines.push(`Env:    ${slot.env_var} = ${slot.value}`)
    lines.push(`Note:   no override in TOML`)
  }
  lines.push(`Range:  [${clamp.min}, ${clamp.max}]`)
  return lines.join('\n')
}

function BudgetRow({ label, slot, manifest, clamp }: {
  label: string
  slot: BudgetSlot
  manifest: string | null
  clamp: { min: number; max: number }
}) {
  const isOverride = slot.source === 'override'
  const isInvalid = slot.source === 'override_invalid'
  const delta = slot.value - slot.env_default
  const deltaText = delta === 0
    ? null
    : delta > 0
      ? `+${delta} (env 기준)`
      : `${delta} (env 기준)`

  let valueClass: string
  if (isInvalid) {
    valueClass = 'text-[var(--bad-light)] underline decoration-wavy decoration-red-400 underline-offset-4 cursor-help'
  } else if (isOverride) {
    valueClass = 'text-[var(--color-fg-secondary)] underline decoration-dotted decoration-amber-300/60 underline-offset-4 cursor-help'
  } else {
    valueClass = 'text-[var(--color-fg-muted)] cursor-help'
  }

  return html`
    <div class="flex items-center justify-between py-2 px-3 rounded-[var(--r-1)] bg-[var(--color-bg-surface)]">
      <span class="text-xs text-[var(--color-fg-muted)]">${label}</span>
      <div class="flex items-center gap-2">
        ${isOverride && deltaText
          ? html`<span class="text-3xs text-[var(--color-fg-muted)] tabular-nums">${deltaText}</span>`
          : null}
        <span
          class="text-xs font-medium tabular-nums ${valueClass}"
          title=${buildBudgetTooltip(slot, manifest, clamp)}
        >${slot.value}</span>
        <${BudgetSourceBadge} source=${slot.source} />
      </div>
    </div>
  `
}

function TurnBudgetPanel({ keeper }: { keeper: Keeper }) {
  const budget = keeper.turn_budget
  if (!budget) {
    return html`
      <div class="text-2xs text-[var(--color-fg-muted)] italic">
        턴 예산 정보를 아직 수신하지 못했습니다. 서버 재시작 후 확인해주세요.
      </div>
    `
  }

  const hasOverride =
    budget.reactive.source === 'override' ||
    budget.scheduled_autonomous.source === 'override'
  const hasInvalid =
    budget.reactive.source === 'override_invalid' ||
    budget.scheduled_autonomous.source === 'override_invalid'
  const clamp = { min: budget.clamp_min, max: budget.clamp_max }

  return html`
    <div class="flex flex-col gap-1.5">
      <div class="flex items-center gap-2 mb-1">
        <${SectionHeader} size="xs">턴 예산 (OAS 호출당)</${SectionHeader}>
        ${hasInvalid
          ? html`<${StatusChip} tone="bad" uppercase=${true} class="font-semibold">invalid override</${StatusChip}>`
          : hasOverride
            ? html`<${StatusChip} tone="warn" uppercase=${true} class="font-semibold">override</${StatusChip}>`
            : html`<${StatusChip} tone="ok" uppercase=${true} class="font-medium">inherited</${StatusChip}>`}
      </div>
      <${BudgetRow}
        label="반응형"
        slot=${budget.reactive}
        manifest=${budget.manifest_path}
        clamp=${clamp}
      />
      <${BudgetRow}
        label="예약 자율"
        slot=${budget.scheduled_autonomous}
        manifest=${budget.manifest_path}
        clamp=${clamp}
      />
      <span class="text-2xs text-[var(--color-fg-muted)] leading-snug mt-1">
        반응형 = 보드/멘션 반응 턴 예산, 예약 자율 = 자율 주기 턴 예산.
        값에 마우스를 올리면 설정 출처와 기본값 비교를 확인할 수 있습니다.
      </span>
    </div>
  `
}

export function TurnBudgetSection({ keeper }: { keeper: Keeper }) {
  const diverges = hasTurnBudgetDivergence(keeper)
  return html`
    <${CollapsibleSection}
      title=${html`터 예산 ${diverges ? html`<span class="text-3xs text-[var(--color-status-warn)] font-normal normal-case tracking-normal">(재정의됨)</span>` : null}`}
      open=${diverges}
      dotClass=${diverges ? 'bg-[var(--warn-10)]' : 'bg-accent/50'}
    >
      <${TurnBudgetPanel} keeper=${keeper} />
    <//>
  `
}

// ── Runtime Signals ──────────────────────────────────────

// Helper: format a 0–1 ratio as percentage or '-'
function fmtRate(v: number | undefined): string {
  return v != null ? `${(v * 100).toFixed(1)}%` : '-'
}

// Helper: format a float with fixed decimals or '-'
function fmtFixed(v: number | undefined, digits = 3): string {
  return v != null ? v.toFixed(digits) : '-'
}

// Helper: format an integer count or '-'
function fmtCount(v: number | undefined): string | number {
  return v != null ? v : '-'
}

interface SignalGroup {
  title: string
  rows: Array<{ label: string; value: string | number }>
}

/**
 * Filter SignalGroups by a case-insensitive substring match on row labels.
 * Empty/whitespace query returns the input reference unchanged (no allocation).
 * Groups with no matching rows are dropped. Input is not mutated.
 */
export function filterSignalGroups(
  groups: readonly SignalGroup[],
  query: string,
): readonly SignalGroup[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return groups
  const out: SignalGroup[] = []
  for (const group of groups) {
    const matchedRows = group.rows.filter(r => r.label.toLowerCase().includes(needle))
    if (matchedRows.length > 0) {
      out.push({ title: group.title, rows: matchedRows })
    }
  }
  return out
}

function countSignalRows(groups: readonly SignalGroup[]): number {
  let total = 0
  for (const group of groups) total += group.rows.length
  return total
}

export function RuntimeSignals({ keeper }: { keeper: Keeper }) {
  const [signalQuery, setSignalQuery] = useState('')
  const mw = keeper.metrics_window

  // Quality/rate metrics only — raw counts (handoffs, compactions, turns)
  // are authoritative in KpiGrid to avoid duplication.
  const groups: SignalGroup[] = [
    {
      title: '폴백',
      rows: [
        { label: '전체 폴백', value: fmtRate(mw?.fallback_rate) },
        { label: '모델 폴백', value: fmtRate(mw?.model_fallback_rate) },
        { label: '프로액티브 폴백', value: fmtRate(mw?.proactive_fallback_rate) },
      ],
    },
    {
      title: 'LLM 응답 정렬',
      rows: [
        { label: '목표 일치도', value: fmtFixed(mw?.goal_alignment_avg) },
        { label: '응답 일치도', value: fmtFixed(mw?.response_alignment_avg) },
        { label: '목표 이탈도', value: fmtFixed(mw?.goal_drift_avg) },
        { label: '반복 패턴 위험도', value: fmtFixed(mw?.repetition_risk_avg) },
      ],
    },
    {
      title: '자율 행동 & 반응',
      rows: [
        { label: '자동 성찰 비율', value: fmtRate(mw?.auto_reflect_rate) },
        { label: '자동 계획 비율', value: fmtRate(mw?.auto_plan_rate) },
        { label: '자동 컴팩션 비율', value: fmtRate(mw?.auto_compact_rate) },
        { label: '자동 핸드오프 비율', value: fmtRate(mw?.auto_handoff_rate) },
        { label: '가드레일 정지', value: fmtCount(mw?.guardrail_stop_count) },
        { label: '멘션 반응', value: fmtCount(keeper.mention_reactive_turn_count) },
        { label: '프리뷰 유사도', value: fmtRate(mw?.proactive_preview_similarity_avg) },
      ],
    },
    {
      title: '드리프트 보정',
      rows: [
        { label: '보정 횟수', value: fmtCount(mw?.drift_applied_count) },
        { label: '보정 비율', value: fmtRate(mw?.drift_applied_rate) },
        { label: '개입 비중', value: fmtRate(mw?.intervention_share) },
        { label: '턴당 개입', value: fmtFixed(mw?.intervention_per_turn, 2) },
      ],
    },
    {
      title: '메모리 & 컴팩션',
      rows: [
        { label: '메모리 통과율', value: fmtRate(mw?.memory_pass_rate) },
        { label: '메모리 평균 점수', value: fmtFixed(mw?.memory_avg_score) },
        { label: '메모리 교정', value: fmtCount(mw?.memory_corrections) },
        { label: '교정 성공', value: fmtCount(mw?.memory_correction_success) },
        { label: '컴팩션 드롭 비율', value: fmtRate(mw?.memory_compaction_drop_ratio) },
        { label: '컴팩션 절감', value: fmtRate(mw?.compaction_saved_ratio) },
        { label: '평균 절감 토큰', value: fmtFixed(mw?.avg_compaction_saved_tokens, 0) },
      ],
    },
  ]

  // Filter out groups where all rows are '-'
  const visibleGroups = groups
    .map(g => ({
      ...g,
      rows: g.rows.filter(r => r.value !== '-' && r.value !== '\u2014' && r.value !== ''),
    }))
    .filter(g => g.rows.length > 0)

  const topListSections = [
    topListDistribution(mw?.top_tools, 'tool', '주요 도구'),
    topListDistribution(mw?.top_models, 'model', '주요 모델'),
    topListDistribution(mw?.top_work_kinds, 'kind', '주요 작업 종류'),
  ].filter((section): section is {
    title: string
    subtitle: string
    items: DistributionItem[]
  } => section !== null)

  if (visibleGroups.length === 0 && topListSections.length === 0) return null

  const filteredGroups = filterSignalGroups(visibleGroups, signalQuery)
  const totalRows = countSignalRows(visibleGroups)
  const matchedRows = countSignalRows(filteredGroups)
  const isFiltering = signalQuery.trim() !== ''
  const showEmptyState = isFiltering && matchedRows === 0

  return html`
    <div class="flex flex-col gap-3">
      ${totalRows > 0
        ? html`
            <div class="flex items-center gap-2">
              <${TextInput}
                type="search"
                class="flex-1 min-w-0 !py-1.5 !px-2 !text-2xs"
                placeholder="신호 지표 필터 (예: 폴백, 메모리, 컴팩션)"
                ariaLabel="런타임 신호 지표 필터"
                value=${signalQuery}
                onInput=${(event: Event) => {
                  const target = event.currentTarget as HTMLInputElement | null
                  setSignalQuery(target?.value ?? '')
                }}
              />
              ${isFiltering
                ? html`<span class="text-3xs text-[var(--color-fg-muted)] tabular-nums whitespace-nowrap">${matchedRows}/${totalRows}</span>`
                : null}
            </div>
          `
        : null}
      ${showEmptyState
        ? html`
            <div class="py-3 px-3 rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] text-2xs text-[var(--color-fg-muted)] italic">
              필터 결과 없음 (${totalRows} items)
            </div>
          `
        : null}
      ${filteredGroups.map(g => html`
        <div class="flex flex-col gap-1">
          <${SectionHeader} size="xs" class="px-1">${g.title}</${SectionHeader}>
          <div class="flex flex-col gap-1">
            ${g.rows.map(r => html`<${SignalRow} label=${r.label} value=${r.value} />`)}
          </div>
        </div>
      `)}
      ${topListSections.length > 0
        ? html`
            <div class="grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-3">
              ${topListSections.map(section => html`
                <${DistributionBars}
                  title=${section.title}
                  subtitle=${section.subtitle}
                  items=${section.items}
                  valueFormatter=${(value: number) => `${value}`}
                  emptyLabel="집계가 아직 없습니다."
                />
              `)}
            </div>
          `
        : null}
    </div>
  `
}

function topListDistribution(
  rawItems: unknown,
  key: 'tool' | 'model' | 'kind',
  title: string,
): {
  title: string
  subtitle: string
  items: DistributionItem[]
} | null {
  if (!Array.isArray(rawItems)) return null
  const items: DistributionItem[] = []
  for (const item of rawItems) {
    if (typeof item !== 'object' || item === null) continue
    const label = typeof item[key] === 'string' ? item[key] : null
    const count = typeof item.count === 'number' && Number.isFinite(item.count) ? item.count : null
    if (!label || count == null || count <= 0) continue
    items.push({
      label,
      value: count,
      detail: key === 'tool'
        ? '최근 sliding window 호출 빈도'
        : key === 'model'
          ? '최근 sliding window 사용 빈도'
          : '최근 sliding window 작업 빈도',
      tone: key === 'model' ? 'warn' : key === 'kind' ? 'ok' : 'accent',
    })
    if (items.length >= 5) break
  }
  if (items.length === 0) return null
  return {
    title,
    subtitle: 'metrics_window Top-N 집계를 막대 형태로 표시합니다.',
    items,
  }
}

// ── Neighborhood & Tool Audit ────────────────────────────

export function KeeperNeighborhood({ keeper }: { keeper: Keeper }) {
  useEffect(() => {
    void loadKeeperConfig(keeper.name)
  }, [keeper.name])

  const keeperConfig = peekLoadedKeeperConfig(keeper.name)
  const configLoadStatus = peekKeeperConfigLoadStatus(keeper.name)
  const namespaceStatus = operatorSnapshot.value?.root ?? {}
  const missionBrief = resolveKeeperMissionBrief(keeper)
  const toolPolicy = resolveKeeperToolPolicy(keeperConfig, configLoadStatus)
  const observedAudit = resolveKeeperObservedToolAudit(keeper, missionBrief)
  const allowedTools = toolPolicy.resolvedAllowlist
  const observedTools = observedAudit.latestToolNames
  const toolCallCount = observedAudit.latestToolCallCount
  const auditSource = observedAudit.toolAuditSource
  const auditAt = observedAudit.toolAuditAt
  const namespaceName =
    namespaceStatus.project ?? serverStatus.value?.project ?? 'default'
  const project = namespaceStatus.project ?? serverStatus.value?.project ?? 'N/A'
  const clusterRaw = namespaceStatus.cluster ?? serverStatus.value?.cluster ?? null
  const clusterVisible = clusterRaw && clusterRaw !== 'unknown' && clusterRaw !== 'default' && clusterRaw !== 'N/A'
  const allowlistFallback = toolAuditStateLabel(allowlistEmptyState(keeper))
  const observedFallback = toolAuditStateLabel(observedToolsEmptyState(keeper, auditSource))
  const metadataFallback = toolAuditStateLabel(auditMetadataState(keeper, auditSource))
  const runtimeState = linkedRuntimeState(keeper)
  const currentTaskLabel = resolveKeeperCurrentTaskLabel(keeper)
  const skillRouteLabel =
    keeper.skill_primary
    ?? (runtimeState === 'offline' ? 'offline' : 'not_collected')
  const policyLoading = toolPolicy.source === 'loading'
  const policyError = toolPolicy.source === 'error'
  const policyLoaded = toolPolicy.source === 'keeper_config'
  const unavailablePolicyLabel = policyError ? 'config_error' : 'config_unavailable'
  const allowedToolCountLabel =
    allowedTools.length > 0
      ? String(allowedTools.length)
      : policyLoading
        ? 'loading'
        : policyLoaded
          ? allowlistFallback
          : unavailablePolicyLabel
  const openToolsQuery = allowedTools[0] ?? observedTools[0] ?? null

  return html`
    <div class="flex flex-col gap-1.5">
      <${SignalRow} label="프로젝트 범위" value=${namespaceName} />
      <${SignalRow} label="프로젝트" value=${project} />
      ${clusterVisible ? html`<${SignalRow} label="클러스터" value=${clusterRaw} />` : null}
      <${SignalRow} label="현재 태스크" value=${currentTaskLabel} />
      <${SignalRow} label="스킬 경로" value=${skillRouteLabel} />
      <${SignalRow} label="컨텍스트 출처" value=${keeper.context_source ?? keeper.context?.source ?? '-'} />
      <${SignalRow} label="허용 도구 수" value=${allowedToolCountLabel} />

      <div class="flex justify-end mt-1">
        <${ActionButton}
          variant="ghost"
          size="md"
          class="!bg-[var(--color-bg-surface)] !text-[var(--color-fg-muted)] hover:!text-[var(--color-fg-primary)] hover:!bg-[var(--color-bg-hover)]"
          disabled=${!openToolsQuery}
          onClick=${() => { openToolsInventory(openToolsQuery) }}
        >
          도구 패널 열기
        <//>
      </div>

      <div class="flex items-center justify-between mt-3">
        <${SectionHeader} size="xs">허용된 도구</${SectionHeader}>
        <span class="text-3xs text-[var(--color-fg-muted)]">${policyLoading ? '로딩 중' : policyError ? '설정 오류' : 'read-only'}</span>
      </div>

      <span class="text-2xs text-[var(--color-fg-muted)] leading-snug">
        ${policyLoading
          ? '허용 도구 목록을 불러오는 중입니다.'
          : policyLoaded
            ? '이 키퍼가 현재 사용할 수 있는 도구 목록입니다.'
            : policyError
              ? '허용 도구 목록 로드에 실패했습니다.'
              : '허용 도구 목록을 아직 확인할 수 없습니다.'}
      </span>
      <${AllowlistPreview}
        tools=${allowedTools}
        emptyLabel=${policyLoading ? 'loading' : policyLoaded ? allowlistFallback : unavailablePolicyLabel}
      />

      <${ToolSection}
        title="관측된 도구"
        description="최근 실행에서 감지된 도구"
        tools=${observedTools}
        fallback=${observedFallback}
      />

      <${SignalRow} label="도구 호출" value=${typeof toolCallCount === 'number' ? toolCallCount : observedFallback === 'none_recent' ? 0 : metadataFallback} />
      <div class="flex items-center justify-between py-2 px-3 rounded-[var(--r-1)] bg-[var(--color-bg-surface)]">
        <span class="text-xs text-[var(--color-fg-muted)]">감사</span>
        <span class="text-xs font-medium text-[var(--color-fg-secondary)]">${auditSource ?? metadataFallback}${auditAt ? html` · <${TimeAgo} timestamp=${auditAt} />` : ''}</span>
      </div>

    </div>
  `
}
