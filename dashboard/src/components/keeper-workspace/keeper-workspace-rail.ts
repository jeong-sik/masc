// Keeper Workspace — context rail (right). Ported to the keeper-v2 prototype DOM
// (rails.jsx ContextRail): `.ctx` → `.ctx-scroll` → `.ctx-sec` sections (주의 /
// 런타임 `.rtc-card` / 처리량 `.tps-card` / 컨텍스트 `.ctx-card` / 소유 태스크
// `.ctx-list`), styled by the vendored SSOT CSS. Live wiring (Keeper object +
// tasks store + masc_keeper_compact) is unchanged; only the DOM/classes changed.
// Data gaps (runtime capability flags, effort segments, compaction/memory
// inspectors) are MARKED, never faked.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { useEffect, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { shellAuthSummary, tasks } from '../../store'
import type { Keeper, Task } from '../../types'
import type { KeeperRuntimeLensConfigDriftAxis } from '../../api/keeper-runtime-trace'
import { navigate } from '../../router'
import {
  keeperBucket,
  keeperModelLabel,
  phaseTokenFromKeeper,
  keeperRuntimeLabel,
} from './keeper-workspace-shared'
import { CountBadge } from '../v2/primitives-v2'
import { callMcpTool } from '../../api/mcp'
import { showToast } from '../common/toast'
import { requestConfirm } from '../common/confirm-dialog'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import { errorToString } from '../../lib/format-string'
import { refreshAfterRuntimeAction } from '../keeper-detail-helpers'
import { contextThresholds } from '../../config/context-thresholds'
import {
  findRuntimeCatalogEntry,
  loadRuntimeCatalog,
  runtimeCatalogState,
} from '../../lib/runtime-catalog-resource'
import { recordManualCompaction } from './compaction-snapshots'
import type { MemoryKeeper } from '../memory-inspector'
import { keepers } from '../../store'

const LazyCompactionInspectorOverlay = lazy(async () => ({
  default: (await import('./compaction-inspector-overlay')).CompactionInspectorOverlay,
}))

const LazyMemoryInspector = lazy(async () => ({
  default: (await import('../memory-inspector')).MemoryInspector,
}))

function contextRatio(keeper: Keeper): number | null {
  const ratio = keeper.context_ratio ?? keeper.context?.context_ratio
  if (typeof ratio !== 'number' || !Number.isFinite(ratio)) return null
  return Math.max(0, Math.min(1, ratio))
}

function contextPercent(keeper: Keeper): number | null {
  const ratio = contextRatio(keeper)
  if (ratio === null) return null
  return Math.max(0, Math.min(100, Math.round(ratio * 100)))
}

function contextMax(keeper: Keeper): number | null {
  const max = keeper.context_max ?? keeper.context?.context_max ?? null
  if (typeof max !== 'number' || !Number.isFinite(max) || max <= 0) return null
  return max
}

function formatK(n: number | null | undefined): string | null {
  if (typeof n !== 'number') return null
  return n >= 1000 ? `${(n / 1000).toFixed(1)}k` : `${n}`
}

function ownedTasks(keeper: Keeper): Task[] {
  return tasks.value.filter(t => t.assignee === keeper.name || (keeper.agent_name != null && t.assignee === keeper.agent_name))
}

function taskStateClass(status: Task['status']): string {
  if (status === 'awaiting_verification') return 'review'
  return ''
}

function nonEmpty(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

function attentionFallback(keeper: Keeper): string | null {
  if (keeper.needs_attention !== true) return null
  const summary = nonEmpty(keeper.runtime_blocker_summary)
  if (summary) return summary
  const reason = nonEmpty(keeper.attention_reason)
  const action = nonEmpty(keeper.next_human_action)
  if (reason && action) return `${reason} · ${action}`
  if (reason) return `주의 원인: ${reason}`
  if (action) return `다음 조치: ${action}`
  return 'runtime_attention.needs_attention=true · 원인/조치 미수신'
}

type AttentionItem = { sev: 'bad' | 'warn'; text: string }

function attentionItems(keeper: Keeper): AttentionItem[] {
  const items: AttentionItem[] = []
  const blocked = keeper.blocked_task_count ?? 0
  if (blocked > 0) items.push({ sev: 'bad', text: `차단된 태스크 ${blocked}건` })
  const awaiting = ownedTasks(keeper).filter(t => t.status === 'awaiting_verification')
  if (awaiting.length > 0) items.push({ sev: 'warn', text: `검증 대기 ${awaiting.length}건` })
  const fallback = items.length === 0 ? attentionFallback(keeper) : null
  if (fallback) items.push({ sev: 'warn', text: fallback })
  return items
}

function AttentionSection({ keeper }: { keeper: Keeper }): VNode | null {
  const items = attentionItems(keeper)
  if (items.length === 0) return null
  return html`
    <div class="ctx-sec">
      <h4 style=${{ display: 'flex', alignItems: 'center', gap: '7px' }}>주의 <${CountBadge}>${items.length}</${CountBadge}></h4>
      <div class="att-list">
        ${items.map((it, i) => html`
          <div class=${`att-item ${it.sev}`} key=${`${it.text}-${i}`}>
            <span class="att-dot" aria-hidden="true"></span>
            <span class="att-text" title=${it.text}>${it.text}</span>
          </div>
        `)}
      </div>
    </div>
  `
}

function formatCtxK(n: number | null | undefined): string | null {
  if (typeof n !== 'number' || !Number.isFinite(n) || n <= 0) return null
  return `${Math.round(n / 1000)}k ctx`
}

function runtimeParameterPolicySummary(
  entry: NonNullable<ReturnType<typeof findRuntimeCatalogEntry>>,
): string | null {
  const policy = entry.parameter_policy
  if (!policy) return null
  const ignored = policy.ignored_sampling_params.join(',')
  const alwaysIgnored = policy.always_ignored_sampling_params.join(',')
  const parts = [
    policy.reasoning_toggle_wire ? policy.reasoning_toggle_wire : null,
    policy.reasoning_replay_policy ? policy.reasoning_replay_policy : null,
    policy.requires_reasoning_replay_on_tool_call ? 'tool-call replay required' : null,
    ignored ? `ignore ${ignored}` : null,
    alwaysIgnored ? `always ${alwaysIgnored}` : null,
  ].filter((value): value is string => Boolean(value))
  return parts.length > 0 ? parts.join(' · ') : null
}

function runtimeRequestToolChoiceSummary(
  entry: NonNullable<ReturnType<typeof findRuntimeCatalogEntry>>,
): string | null {
  const choice = entry.request_config?.tool_choice
  if (!choice?.kind) return null
  return choice.name ? `${choice.kind}:${choice.name}` : choice.kind
}

function runtimeRequestFormatSummary(
  entry: NonNullable<ReturnType<typeof findRuntimeCatalogEntry>>,
): string | null {
  const format = entry.request_config?.response_format
  if (!format?.kind) return null
  return format.has_schema ? `${format.kind}+schema` : format.kind
}

function runtimeRequestConfigSummary(
  entry: NonNullable<ReturnType<typeof findRuntimeCatalogEntry>>,
): string | null {
  const request = entry.request_config
  if (!request) return null
  const sampling = [
    typeof request.temperature === 'number' ? `temp ${request.temperature}` : null,
    typeof request.top_p === 'number' ? `top_p ${request.top_p}` : null,
    typeof request.top_k === 'number' ? `top_k ${request.top_k}` : null,
    typeof request.min_p === 'number' ? `min_p ${request.min_p}` : null,
  ].filter((value): value is string => Boolean(value))
  const toolChoice = runtimeRequestToolChoiceSummary(entry)
  const format = runtimeRequestFormatSummary(entry)
  const requestPath = request.request_path_targets_responses_api
    ? 'responses-api'
    : request.request_path
      ? `path ${request.request_path}`
      : null
  const parts = [
    request.provider_kind ? request.provider_kind : null,
    request.source ? `source ${request.source}` : null,
    requestPath,
    typeof request.max_tokens === 'number' ? `out ${request.max_tokens}` : null,
    typeof request.max_context === 'number' ? `ctx ${request.max_context}` : null,
    sampling.length > 0 ? sampling.join(',') : null,
    request.has_system_prompt ? 'system prompt' : null,
    typeof request.enable_thinking === 'boolean' ? `think ${request.enable_thinking ? 'on' : 'off'}` : null,
    typeof request.preserve_thinking === 'boolean' ? `preserve ${request.preserve_thinking ? 'on' : 'off'}` : null,
    typeof request.clear_thinking === 'boolean' ? `clear ${request.clear_thinking ? 'on' : 'off'}` : null,
    typeof request.thinking_budget === 'number' ? `budget ${request.thinking_budget}` : null,
    request.resolved_reasoning_effort ? `effort ${request.resolved_reasoning_effort}` : null,
    request.glm_clear_thinking ? 'glm clear' : null,
    request.glm_replay_reasoning ? 'glm replay' : null,
    typeof request.tool_stream === 'boolean' ? `tool stream ${request.tool_stream ? 'on' : 'off'}` : null,
    toolChoice ? `tool ${toolChoice}` : null,
    request.disable_parallel_tool_use ? 'parallel off' : null,
    format ? `format ${format}` : null,
    request.has_output_schema ? 'output schema' : null,
    request.cache_system_prompt ? 'cache system' : null,
    typeof request.supports_tool_choice_override === 'boolean'
      ? `tool override ${request.supports_tool_choice_override ? 'on' : 'off'}`
      : null,
    typeof request.supports_structured_output_override === 'boolean'
      ? `schema override ${request.supports_structured_output_override ? 'on' : 'off'}`
      : null,
    request.has_model_capabilities_override ? 'cap override' : null,
    typeof request.seed === 'number' ? `seed ${request.seed}` : null,
    typeof request.internal_model_rotation_count === 'number'
      ? `rotation ${request.internal_model_rotation_count}`
      : null,
    typeof request.num_ctx === 'number' ? `num_ctx ${request.num_ctx}` : null,
    request.keep_alive ? `keep ${request.keep_alive}` : null,
    request.has_previous_response_id ? 'previous response' : null,
    typeof request.connect_timeout_s === 'number' ? `connect ${request.connect_timeout_s}s` : null,
  ].filter((value): value is string => Boolean(value))
  return parts.length > 0 ? parts.join(' · ') : null
}

function runtimeDeclaredSpecSummary(
  entry: NonNullable<ReturnType<typeof findRuntimeCatalogEntry>>,
): string | null {
  const spec = entry.declared_spec
  if (!spec) return null
  const caps = spec.model?.capabilities
  const sampling = [
    caps?.supports_top_k ? 'top_k' : null,
    caps?.supports_min_p ? 'min_p' : null,
    caps?.supports_seed ? 'seed' : null,
  ].filter((value): value is string => Boolean(value))
  const inputs = [
    caps?.supports_multimodal_inputs ? 'multimodal' : null,
    caps?.supports_image_input ? 'image' : null,
    caps?.supports_audio_input ? 'audio' : null,
    caps?.supports_video_input ? 'video' : null,
  ].filter((value): value is string => Boolean(value))
  const formats = [
    caps?.supports_response_format_json ? 'json' : null,
    caps?.supports_structured_output ? 'schema' : null,
  ].filter((value): value is string => Boolean(value))
  const behavior = spec.provider?.behavior_capabilities
  const behaviorParts = behavior
    ? [
        behavior.supports_inline_tools ? 'inline-tools' : null,
        behavior.requires_per_keeper_bridging_for_bound_actor_tools ? 'keeper-bridge' : null,
        behavior.argv_prompt_preflight ? 'argv-preflight' : null,
        behavior.uses_anthropic_caching ? 'anthropic-cache' : null,
        typeof behavior.max_turns_per_attempt === 'number' ? `max-turns ${behavior.max_turns_per_attempt}` : null,
        behavior.tolerates_bound_actor_fallback ? 'bound-fallback' : null,
        behavior.identity_runtime_mcp_header_keys.length > 0
          ? `mcp headers ${behavior.identity_runtime_mcp_header_keys.join(',')}`
          : null,
      ].filter((value): value is string => Boolean(value))
    : []
  const controls = [
    caps?.supports_tool_choice ? 'tool-choice' : null,
    caps?.supports_required_tool_choice ? 'required' : null,
    caps?.supports_named_tool_choice ? 'named' : null,
    caps?.supports_parallel_tool_calls ? 'parallel' : null,
    caps?.supports_extended_thinking ? 'extended-thinking' : null,
    caps?.supports_reasoning_budget ? 'reasoning-budget' : null,
    caps?.supports_native_streaming ? 'native-stream' : null,
    caps?.supports_system_prompt ? 'system-prompt' : null,
    caps?.supports_caching ? 'cache' : null,
    caps?.supports_prompt_caching
      ? `prompt-cache${typeof caps.prompt_cache_alignment === 'number' ? `@${caps.prompt_cache_alignment}` : ''}`
      : null,
    caps?.supports_seed_with_images ? 'seed+images' : null,
    caps?.emits_usage_tokens ? 'usage' : null,
    caps?.supports_computer_use ? 'computer-use' : null,
    caps?.supports_code_execution ? 'code-exec' : null,
  ].filter((value): value is string => Boolean(value))
  let thinking: string | null = null
  if (typeof spec.model?.thinking_support === 'boolean') {
    thinking = spec.model.thinking_support ? 'think on' : 'think off'
  }
  const parts = [
    spec.provider?.api_format ? spec.provider.api_format : null,
    spec.provider?.protocol ? spec.provider.protocol : null,
    spec.provider?.transport ? `transport ${spec.provider.transport}` : null,
    spec.provider?.auth_kind ? `auth ${spec.provider.auth_kind}` : null,
    spec.provider?.is_non_interactive ? 'non-interactive' : null,
    typeof spec.provider?.custom_header_count === 'number' ? `headers ${spec.provider.custom_header_count}` : null,
    typeof spec.provider?.connect_timeout_s === 'number' ? `connect ${spec.provider.connect_timeout_s}s` : null,
    behaviorParts.length > 0 ? `behavior ${behaviorParts.join(',')}` : null,
    typeof spec.model?.max_context === 'number' ? `ctx ${spec.model.max_context}` : null,
    typeof spec.model?.temperature === 'number' ? `temp ${spec.model.temperature}` : null,
    typeof spec.model?.tools_support === 'boolean' ? `tools ${spec.model.tools_support ? 'on' : 'off'}` : null,
    typeof spec.model?.streaming === 'boolean' ? `stream ${spec.model.streaming ? 'on' : 'off'}` : null,
    typeof spec.model?.preserve_thinking === 'boolean'
      ? `preserve ${spec.model.preserve_thinking ? 'on' : 'off'}`
      : null,
    thinking,
    typeof spec.model?.max_thinking_budget === 'number' ? `budget ${spec.model.max_thinking_budget}` : null,
    caps?.thinking_control_format ? caps.thinking_control_format : null,
    typeof caps?.max_output_tokens === 'number' ? `out ${caps.max_output_tokens}` : null,
    formats.length > 0 ? `format ${formats.join(',')}` : null,
    inputs.length > 0 ? `input ${inputs.join(',')}` : null,
    sampling.length > 0 ? `sampling ${sampling.join(',')}` : null,
    controls.length > 0 ? `controls ${controls.join(',')}` : null,
    spec.model?.match_prefixes.length ? `match ${spec.model.match_prefixes.join(',')}` : null,
    spec.binding?.is_default ? 'default' : null,
    typeof spec.binding?.max_concurrent === 'number' ? `conc ${spec.binding.max_concurrent}` : null,
    typeof spec.binding?.price_input === 'number' ? `price-in ${spec.binding.price_input}` : null,
    typeof spec.binding?.price_output === 'number' ? `price-out ${spec.binding.price_output}` : null,
    spec.binding?.keep_alive ? `keep ${spec.binding.keep_alive}` : null,
    typeof spec.binding?.num_ctx === 'number' ? `num_ctx ${spec.binding.num_ctx}` : null,
  ].filter((value): value is string => Boolean(value))
  return parts.length > 0 ? parts.join(' · ') : null
}

function runtimeEffectiveCapabilitySummary(
  entry: NonNullable<ReturnType<typeof findRuntimeCatalogEntry>>,
): string | null {
  const caps = entry.effective_capabilities
  if (!caps) return null
  const sampling = [
    caps.supports_top_k ? 'top_k' : null,
    caps.supports_min_p ? 'min_p' : null,
    caps.supports_seed ? 'seed' : null,
  ].filter((value): value is string => Boolean(value))
  const formats = [
    caps.supports_response_format_json ? 'json' : null,
    caps.supports_structured_output ? 'schema' : null,
  ].filter((value): value is string => Boolean(value))
  const parts = [
    typeof caps.max_context_tokens === 'number' ? `ctx ${caps.max_context_tokens}` : null,
    typeof caps.max_output_tokens === 'number' ? `out ${caps.max_output_tokens}` : null,
    caps.supports_tools ? 'tools' : null,
    caps.supports_tool_choice
      ? `tool_choice${[
        caps.supports_required_tool_choice ? 'required' : null,
        caps.supports_named_tool_choice ? 'named' : null,
        caps.supports_parallel_tool_calls ? 'parallel' : null,
      ].filter((value): value is string => Boolean(value)).map(flag => `+${flag}`).join('')}`
      : null,
    caps.supports_runtime_mcp_tools ? 'runtime-mcp-tools' : null,
    caps.supports_runtime_tool_events ? 'runtime-tool-events' : null,
    formats.length > 0 ? `format ${formats.join(',')}` : null,
    sampling.length > 0 ? `sampling ${sampling.join(',')}` : null,
    caps.modality_priority ? `modality ${caps.modality_priority}` : null,
    caps.assistant_tool_content_format ? `tool-content ${caps.assistant_tool_content_format}` : null,
    caps.supports_reasoning ? 'reasoning' : null,
    caps.supports_extended_thinking ? 'extended thinking' : null,
    caps.supports_reasoning_budget ? 'reasoning budget' : null,
    caps.accepted_reasoning_efforts && caps.accepted_reasoning_efforts.length > 0
      ? `effort ${caps.accepted_reasoning_efforts.join(',')}`
      : null,
    caps.preserve_thinking_control_format ? `preserve ${caps.preserve_thinking_control_format}` : null,
    caps.reasoning_output_format ? `reasoning-out ${caps.reasoning_output_format}` : null,
    caps.reasoning_streaming_format?.kind ? `reasoning-stream ${caps.reasoning_streaming_format.kind}` : null,
    caps.reasoning_replay_override ? `replay ${caps.reasoning_replay_override}` : null,
    caps.task ? `task ${caps.task}` : null,
    caps.supports_native_streaming ? 'native-stream' : null,
    caps.supports_system_prompt ? 'system-prompt' : null,
    caps.supports_prompt_caching
      ? `prompt-cache${typeof caps.prompt_cache_alignment === 'number' ? `@${caps.prompt_cache_alignment}` : ''}`
      : null,
    caps.supports_caching ? 'cache' : null,
    caps.supports_seed_with_images ? 'seed+images' : null,
    caps.supports_computer_use ? 'computer-use' : null,
    caps.supports_code_execution ? 'code-exec' : null,
    caps.emits_usage_tokens ? 'usage' : null,
    caps.supported_models && caps.supported_models.length > 0 ? `models ${caps.supported_models.length}` : null,
  ].filter((value): value is string => Boolean(value))
  return parts.length > 0 ? parts.join(' · ') : null
}

function RuntimeSection({
  keeper,
  drift,
}: {
  keeper: Keeper
  drift: KeeperRuntimeLensConfigDriftAxis | null
}): VNode {
  useEffect(() => {
    loadRuntimeCatalog()
  }, [])

  const model = keeperModelLabel(keeper)
  const runtime = keeperRuntimeLabel(keeper)
  // The card's runtime id is the *live* runtime the keeper is running (from its
  // meta, via the execution snapshot). Saving a new runtime in the config
  // editor changes the *assigned* runtime (runtime.toml); the running keeper
  // keeps its current runtime until its next turn-up. Surface that pending
  // assignment here so a save that "does nothing" visibly is instead shown as
  // "assigned X, still running Y". The drift axis is the config-domain read
  // model — the rail does not reach into the config editor's write signal.
  const pendingRuntime =
    drift && drift.runtime_override ? drift.default_runtime_id : null
  const catalog = runtimeCatalogState.value.status === 'loaded' ? runtimeCatalogState.value.data : []
  const entry = runtime ? findRuntimeCatalogEntry(catalog, runtime) : null
  const ctxK = formatCtxK(entry?.max_context ?? contextMax(keeper))
  const capabilitiesDeclared = entry?.capabilities_declared !== false
  // Read-only capability readout (audit P7-4). multimodal = accepts non-text
  // input; effort adjustability mirrors the runtime editor's rtCaps derivation
  // (reasoning-effort mode or a reasoning-budget knob). Both come from the
  // /api/v1/providers projection — no per-keeper mutation here (deferred).
  const multimodal = capabilitiesDeclared
    ? Boolean(entry?.supports_multimodal_inputs || entry?.supports_image_input)
    : null
  const effortMode = entry?.thinking_control_format ?? null
  const effortControlled = effortMode !== null && effortMode !== 'none'
  const effortAdjustable = effortMode === 'reasoning-effort' || Boolean(entry?.supports_reasoning_budget)
  const effectiveCapabilities = entry ? runtimeEffectiveCapabilitySummary(entry) : null
  const parameterPolicy = entry ? runtimeParameterPolicySummary(entry) : null
  const requestConfig = entry ? runtimeRequestConfigSummary(entry) : null
  const declaredSpec = entry ? runtimeDeclaredSpecSummary(entry) : null

  return html`
    <div class="ctx-sec">
      <h4>런타임</h4>
      <div class="rtc-card">
        <div class="rtc-id mono">${runtime ?? '런타임 미수신'}</div>
        ${pendingRuntime
          ? html`<div
              class="rtc-drift"
              data-testid="runtime-drift"
              title="저장된 런타임 지정은 키퍼가 다음 turn-up(재시작)할 때 적용됩니다. 현재 표시된 런타임은 지금 실제로 실행 중인 것입니다."
            >
              지정됨 <span class="mono">${pendingRuntime}</span> · 재시작 시 적용
            </div>`
          : null}
        <div class="rtc-model mono">
          ${entry?.model_api_name ?? model ?? '—'}${ctxK ? html` · ${ctxK}` : null}
        </div>
        ${entry
          ? html`
              <div class="rtc-flags">
                <span class=${`rtc-flag ${entry.tools_support ? 'on' : 'off'}`}>
                  ${entry.tools_support ? '✓' : '✕'} tools
                </span>
                <span class=${`rtc-flag ${entry.thinking_support ? 'on' : 'off'}`}>
                  ${entry.thinking_support ? '✓' : '✕'} thinking
                </span>
                <span class=${`rtc-flag ${entry.streaming ? 'on' : 'off'}`}>
                  ${entry.streaming ? '✓' : '✕'} streaming
                </span>
                <span class=${`rtc-flag ${multimodal === true ? 'on' : 'off'}`}>
                  ${multimodal === null ? '—' : multimodal ? '✓' : '✕'} multimodal
                </span>
              </div>
            `
          : html`<div class="rtc-na" data-missing="runtime-capabilities">능력 정보 미수신</div>`}
        <div class="rtc-effort">
          <span class="rtc-effort-k">effort</span>
          ${/* Undeclared capabilities mean the effort mode is unknown, not a
               definitive "no control" — the default-filled thinking_control_format
               ('none') is not authoritative. Mirror the multimodal flag's unknown
               handling instead of asserting a value the config never declared. */ ''}
          ${!entry || !capabilitiesDeclared
            ? html`<span class="rtc-eff-na" data-missing="runtime-effort">조정 정보 미수신</span>`
            : effortControlled
              ? html`<span class="rtc-eff-na" data-effort-mode=${effortMode}>${effortMode} · ${effortAdjustable ? '조정 가능' : '고정'}</span>`
              : html`<span class="rtc-eff-na" data-effort-mode="none">effort 제어 없음</span>`}
        </div>
        ${parameterPolicy
          ? html`
              <div class="rtc-effort">
                <span class="rtc-effort-k">params</span>
                <span class="rtc-eff-na" title=${parameterPolicy}>${parameterPolicy}</span>
              </div>
            `
          : null}
        ${requestConfig
          ? html`
              <div class="rtc-effort">
                <span class="rtc-effort-k">request</span>
                <span class="rtc-eff-na" title=${requestConfig}>${requestConfig}</span>
              </div>
            `
          : null}
        ${declaredSpec
          ? html`
              <div class="rtc-effort">
                <span class="rtc-effort-k">declared</span>
                <span class="rtc-eff-na" title=${declaredSpec}>${declaredSpec}</span>
              </div>
            `
          : null}
        ${effectiveCapabilities
          ? html`
              <div class="rtc-effort">
                <span class="rtc-effort-k">caps</span>
                <span class="rtc-eff-na" title=${effectiveCapabilities}>${effectiveCapabilities}</span>
              </div>
            `
          : null}
      </div>
    </div>
  `
}

function compactionGatePct(keeper: Keeper): number {
  const raw = keeper.compaction_ratio_gate
  const ratio = typeof raw === 'number' && Number.isFinite(raw) && raw > 0
    ? raw
    : contextThresholds.value.compacting
  return Math.max(1, Math.min(99, Math.round(ratio * 100)))
}

function compactRequiresForce(keeper: Keeper): boolean {
  const phase = phaseTokenFromKeeper(keeper)
  if (phase === 'overflowed' || phase === 'paused' || phase === 'compacting') return false
  if (phase === 'running' || phase === 'failing') return true
  const status = keeper.status.toLowerCase()
  return status === 'running' || status === 'active' || status === 'busy' || status === 'failing'
}

function ContextSection({
  keeper,
  onOpenCompaction,
  onOpenMemory,
}: {
  keeper: Keeper
  onOpenCompaction: () => void
  onOpenMemory: () => void
}): VNode {
  const [compacting, setCompacting] = useState(false)
  const pct = contextPercent(keeper)
  const compactAt = compactionGatePct(keeper)
  const hot = pct !== null && pct >= compactAt
  const max = contextMax(keeper)
  const baseTokens = keeper.context_tokens ?? keeper.context?.context_tokens ?? null
  const tokens = formatK(baseTokens)
  const maxLabel = formatK(max)
  const compactionCount = keeper.compaction_count ?? null
  const hasCompactionHistory = typeof compactionCount === 'number' && compactionCount > 0
  const hasMeterData = pct !== null && (pct > 0 || max !== null)
  const compactAccess = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  const canCompact = compactAccess.allowed && !compacting
  const compactReason = compactAccess.reason ?? '컴팩션 실행 권한이 필요합니다.'
  const runCompact = () => {
    if (!compactAccess.allowed) {
      showToast(compactReason, 'error', 6000)
      return
    }
    void (async () => {
      const force = compactRequiresForce(keeper)
      if (force) {
        const confirmed = await requestConfirm({
          title: 'Force keeper compact',
          message: `${keeper.name} is not in an explicit overflow/paused compaction phase. Run masc_keeper_compact with force=true?`,
          confirmText: 'Force compact',
          tone: 'warning',
        })
        if (!confirmed) return
      }
      setCompacting(true)
      try {
        const raw = await callMcpTool('masc_keeper_compact', { name: keeper.name, force })
        const parsed = JSON.parse(raw) as { before_tokens?: number; after_tokens?: number; phase_after?: string }
        const before = formatK(parsed.before_tokens)
        const after = formatK(parsed.after_tokens)
        recordManualCompaction(
          keeper.name,
          parsed.before_tokens,
          parsed.after_tokens,
          keeperRuntimeLabel(keeper) ?? '—',
        )
        showToast(
          before && after ? `${keeper.name} compact 완료: ${before} -> ${after}` : `${keeper.name} compact 완료`,
          'success',
        )
        await refreshAfterRuntimeAction()
      } catch (err) {
        showToast(`compact 실패: ${errorToString(err)}`, 'error', 8000)
      } finally {
        setCompacting(false)
      }
    })()
  }

  // The "윈도우 사용량" label was redundant under the section's "컨텍스트"
  // heading — the percentage and the 사용/전체 line below are self-explanatory.
  const usageHeader = html`
    <div class="ctx-meter-head">
      <span class=${`ctx-meter-pct mono${hot ? ' hot' : ''}`}>${pct ?? 0}%</span>
    </div>
  `

  return html`
    <div class="ctx-sec">
      <h4>컨텍스트</h4>
      <div class="ctx-card">
        ${hasMeterData
          ? html`
              ${usageHeader}
              <div class="meter-wrap">
                <div
                  class=${`meter${hot ? ' hot' : ''}`}
                  role="meter"
                  aria-label="컨텍스트 윈도우 사용률"
                  aria-valuenow=${pct ?? 0}
                  aria-valuemin="0"
                  aria-valuemax="100"
                ><span style=${{ width: `${pct ?? 0}%` }}></span></div>
                <span class=${`meter-mark${hot ? ' hot' : ''}`} style=${{ left: `${compactAt}%` }}>
                  <i class="meter-mark-lbl">compact ${compactAt}%</i>
                </span>
              </div>
            `
          : html`<div class="ctx-empty" data-missing="context-window"><strong>윈도우 사용률 미수신</strong><span>런타임이 전체 윈도우 총량을 아직 보내지 않았습니다.</span></div>`}
        <div class="ctx-tok">
          <span class="mono">${tokens ?? '—'}</span>
          <span class="ctx-tok-sep">/</span>
          <span class="mono ctx-tok-full">${maxLabel ?? '—'}</span>
          <span class="ctx-tok-lbl">사용 / 전체 윈도우</span>
        </div>
        <div class="cmp-actions">
          <button
            type="button"
            class=${`cmp-run${compacting ? ' busy' : ''}`}
            disabled=${!canCompact}
            title=${compactAccess.allowed ? 'masc_keeper_compact 실행' : compactReason}
            onClick=${runCompact}
          >${compacting ? html`<span class="cmp-spin"></span> 컴팩트 실행 중…` : '◉ 지금 컴팩트'}</button>
        </div>
        <button type="button" class="cmp-open" data-testid="open-compaction-inspector" onClick=${onOpenCompaction}>
          ◉ 컴팩션 스냅샷${hasCompactionHistory ? ` · ${compactionCount}` : ''} <span class="cmp-open-sub">before/after 보기</span>
        </button>
        <button type="button" class="cmp-open" data-testid="open-memory-inspector" onClick=${onOpenMemory}>
          ◈ 메모리 보기 <span class="cmp-open-sub">핀 · 스토어 · 회상</span>
        </button>
      </div>
    </div>
  `
}

function OwnedTasksSection({ keeper }: { keeper: Keeper }): VNode {
  const owned = ownedTasks(keeper)
  const openTask = (task: Task) => {
    navigate('workspace', { section: 'planning', task: task.id })
  }
  return html`
    <div class="ctx-sec">
      <h4>소유 태스크</h4>
      <div class="ctx-list">
        ${owned.length
          ? owned.map(t => html`
              <button
                type="button"
                class="tasktag"
                key=${t.id}
                title=${`작업으로 이동 · ${t.id} · ${t.title}`}
                aria-label=${`태스크 열기: ${t.id} ${t.title}`}
                onClick=${() => openTask(t)}
              >
                <div class="tasktag-top">
                  <span class="tid">${t.id}</span>
                  ${t.status ? html`<span class=${`tasktag-state ${taskStateClass(t.status)}`}>${t.status}</span>` : null}
                </div>
                <span class="ttl">${t.title}</span>
              </button>
            `)
          : html`<div style=${{ fontSize: '12px', color: 'var(--text-dim)' }}>할당된 태스크 없음</div>`}
      </div>
    </div>
  `
}

function toMemoryKeeper(k: Keeper): MemoryKeeper {
  const bucket = keeperBucket(k)
  const status = bucket === 'running' ? 'run' : bucket === 'paused' ? 'pause' : 'off'
  return {
    id: k.name,
    ctx: contextRatio(k) ?? 0,
    status,
  }
}

export function KeeperWorkspaceRail({
  keeper,
  runtimeDrift = null,
}: {
  keeper: Keeper
  runtimeDrift?: KeeperRuntimeLensConfigDriftAxis | null
}): VNode {
  const [overlay, setOverlay] = useState<'compaction' | 'memory' | null>(null)
  const memoryKeeper = toMemoryKeeper(keeper)
  const memoryKeepers = keepers.value.map(toMemoryKeeper)

  return html`
    <aside class="ctx" aria-label="키퍼 컨텍스트">
      <div class="ctx-scroll">
        <${AttentionSection} keeper=${keeper} />
        <${RuntimeSection} keeper=${keeper} drift=${runtimeDrift} />
        <${ContextSection}
          keeper=${keeper}
          onOpenCompaction=${() => setOverlay('compaction')}
          onOpenMemory=${() => setOverlay('memory')}
        />
        <${OwnedTasksSection} keeper=${keeper} />
      </div>
    </aside>

    ${overlay === 'compaction'
      ? html`
          <${Suspense} fallback=${html`<div class="turn-overlay" role="dialog" aria-modal="true">컴팩션 스냅샷 로딩…</div>`}>
            <${LazyCompactionInspectorOverlay} keeper=${keeper} onClose=${() => setOverlay(null)} />
          <//>
        `
      : null}
    ${overlay === 'memory'
      ? html`
          <${Suspense} fallback=${html`<div class="turn-overlay" role="dialog" aria-modal="true">Keeper 메모리 로딩…</div>`}>
            <${LazyMemoryInspector}
              keeper=${memoryKeeper}
              keepers=${memoryKeepers}
              onClose=${() => setOverlay(null)}
            />
          <//>
        `
      : null}
  `
}
