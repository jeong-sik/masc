import { html } from 'htm/preact'
import type {
  DashboardEffectiveKeeperSurface,
  DashboardSkillActivation,
  DashboardSkillActivationProjection,
  DashboardSkillReference,
} from '../../api'

interface SkillActivationPanelProps {
  keeperNames: string[]
  selectedKeeper: string | null
  effectiveSurface: DashboardEffectiveKeeperSurface | null | undefined
  activations: DashboardSkillActivationProjection | null | undefined
  loading: boolean
  error: string | null
  onSelectKeeper: (keeperName: string | null) => void
}

function referenceLabel(reference: DashboardSkillReference): string {
  const { source_id, package_id, name } = reference.identity
  return `${source_id}/${package_id}:${name}@${reference.content_revision}`
}

function activationReferenceLabel(activation: DashboardSkillActivation): string {
  return referenceLabel({
    identity: activation.identity,
    content_revision: activation.content_revision,
  })
}

function originLabel(invocation: DashboardSkillActivation['invocation']): string {
  const origin = invocation.origin
  switch (origin.kind) {
    case 'task_instruction':
      return `Task instruction · ${origin.task_id}`
    case 'session_instruction':
      return 'Session instruction'
    case 'task_composition':
      return `Task composition · ${origin.task_id} · ${invocation.kind === 'composition' ? invocation.tool_name : ''}`
    case 'session_composition':
      return `Session composition · ${invocation.kind === 'composition' ? invocation.tool_name : ''}`
  }
}

function servedLabel(activation: DashboardSkillActivation): string {
  if (activation.invocation.kind === 'composition') {
    return `composition invocation · ${activation.invocation.tool_name}`
  }
  const served = activation.invocation.served_content
  return served.kind === 'skill_body'
    ? `body · ${served.bytes} bytes · ${served.sha256}`
    : `resource ${served.relative_path} · ${served.bytes} bytes · ${served.sha256}`
}

function SurfaceReceipt({ surface }: { surface: DashboardEffectiveKeeperSurface }) {
  if (surface.status === 'warming') {
    return html`<div class="text-xs text-[var(--color-fg-muted)]">Keeper surface warming</div>`
  }
  if (surface.status === 'unavailable') {
    return html`
      <div class="text-xs text-[var(--color-status-bad)]" data-testid="skill-surface-unavailable">
        ${surface.reason}: ${surface.detail}
      </div>
    `
  }
  const references = [...surface.instruction_skills, ...surface.composition_skills]
  return html`
    <div class="grid gap-2" data-testid="skill-effective-surface">
      <div class="text-xs text-[var(--color-fg-muted)]">
        ${surface.runtime_id} · ${surface.official_client_kind} · ${surface.count} tools
      </div>
      <code class="text-3xs break-all text-[var(--color-fg-muted)]">
        snapshot ${surface.skill_snapshot_revision} · deferred resource bound ${surface.skill_resource_read_max_bytes ?? 'not configured'}
      </code>
      ${surface.tool_delivery.status === 'suppressed'
        ? html`<div class="text-xs text-[var(--color-status-warn)]" data-testid="skill-tool-delivery-suppressed">
            Tool delivery suppressed · ${surface.tool_delivery.reason}
          </div>`
        : html`<div class="text-xs text-[var(--color-status-good)]">
            Tool delivery active
          </div>`}
      <div class="grid gap-1">
        ${references.length === 0
          ? html`<span class="text-xs text-[var(--color-fg-muted)]">No readable Skills</span>`
          : references.map(reference => html`
              <code key=${referenceLabel(reference)} class="text-3xs break-all">${referenceLabel(reference)}</code>
            `)}
      </div>
      ${surface.tool_surface_sha256
        ? html`<code class="text-3xs break-all text-[var(--color-fg-muted)]">
            surface ${surface.tool_surface_sha256}
          </code>`
        : null}
    </div>
  `
}

function ActivationReceipt({
  projection,
}: {
  projection: DashboardSkillActivationProjection
}) {
  if (projection.status === 'no_session') {
    return html`<div class="text-xs text-[var(--color-fg-muted)]">No Keeper session</div>`
  }
  if (projection.status === 'unavailable') {
    return html`
      <div class="text-xs text-[var(--color-status-bad)]" data-testid="skill-activations-unavailable">
        ${projection.reason}: ${projection.detail}
      </div>
    `
  }
  const summary = projection.summary
  return html`
    <div class="grid gap-2" data-testid="skill-activation-ledger">
      <div class="grid grid-cols-2 md:grid-cols-4 gap-2" data-testid="skill-use-summary">
        <span class="text-xs">session totals</span>
        <span class="text-xs">invoked ${summary.instruction_invocations}</span>
        <span class="text-xs">bodies ${summary.skill_bodies_served}</span>
        <span class="text-xs">resources ${summary.skill_resources_served}</span>
        <span class="text-xs">delivered ${summary.instruction_deliveries}</span>
        <span class="text-xs">actions ${summary.instruction_actions_observed}</span>
        <span class="text-xs">invalid ${summary.invalid_transitions}</span>
        <span class="text-xs">
          compositions ${summary.composition_invocations}/${summary.composition_deliveries}/${summary.composition_actions_observed}
        </span>
      </div>
      <div class="text-xs text-[var(--color-fg-muted)]">
        session ${projection.ledger.session_id} · ${projection.ledger.activations.length} activations · ${projection.ledger.transition_rejections.length} rejected transitions
      </div>
      <div class="grid gap-1" data-testid="skill-scoped-summaries">
        ${projection.scoped_summaries.map(scoped => html`
          <div key=${`${scoped.scope.snapshot_revision}\u0000${scoped.scope.turn_ref}\u0000${scoped.scope.runtime_id}\u0000${referenceLabel(scoped.scope.reference)}`} class="rounded-[var(--r-1)] border border-[var(--color-border-subtle)] p-2 grid gap-1">
            <code class="text-3xs break-all">proof ${referenceLabel(scoped.scope.reference)}</code>
            <code class="text-3xs break-all text-[var(--color-fg-muted)]">
              snapshot ${scoped.scope.snapshot_revision} · keeper turn ${scoped.scope.turn_ref} · runtime ${scoped.scope.runtime_id}
            </code>
            <span class="text-3xs">
              invoked ${scoped.summary.instruction_invocations} · bodies ${scoped.summary.skill_bodies_served} · resources ${scoped.summary.skill_resources_served} · delivered ${scoped.summary.instruction_deliveries} · actions ${scoped.summary.instruction_actions_observed} · compositions ${scoped.summary.composition_invocations}/${scoped.summary.composition_deliveries}/${scoped.summary.composition_actions_observed} · invalid ${scoped.summary.invalid_transitions}
            </span>
          </div>
        `)}
      </div>
      ${projection.ledger.activations.length === 0
        ? html`<span class="text-xs text-[var(--color-fg-muted)]">No activations recorded</span>`
        : projection.ledger.activations.map(activation => html`
            <div key=${activation.skill_tool_use_id} class="rounded-[var(--r-1)] border border-[var(--color-border-subtle)] p-2 grid gap-1">
              <code class="text-3xs break-all">${activationReferenceLabel(activation)}</code>
              <span class="text-3xs">${originLabel(activation.invocation)}</span>
              <code class="text-3xs break-all text-[var(--color-fg-muted)]">
                invoked turn ${activation.agent_core_turn} · id ${activation.skill_tool_use_id} · runtime ${activation.runtime_id} · ${activation.activated_at}
              </code>
              <code class="text-3xs break-all text-[var(--color-fg-muted)]">
                served ${servedLabel(activation)}
              </code>
              <code class="text-3xs break-all text-[var(--color-fg-muted)]">
                ${activation.delivery
                  ? `delivered turn ${activation.delivery.agent_core_turn} · ${activation.delivery.delivered_at}`
                  : 'delivery pending'}
              </code>
              ${activation.actions.map(action => html`
                <code class="text-3xs break-all text-[var(--color-fg-muted)]">
                  action turn ${action.agent_core_turn} · ${action.tool_name} · id ${action.tool_use_id} · ${action.observed_at}
                </code>
              `)}
              <code class="text-3xs break-all text-[var(--color-fg-muted)]">
                snapshot ${activation.snapshot_revision} · keeper turn ${activation.turn_ref}
              </code>
            </div>
          `)}
    </div>
  `
}

export function SkillActivationPanel(props: SkillActivationPanelProps) {
  const {
    keeperNames,
    selectedKeeper,
    effectiveSurface,
    activations,
    loading,
    error,
    onSelectKeeper,
  } = props
  return html`
    <div class="grid gap-3">
      <label class="grid gap-1 text-xs">
        <span class="text-[var(--color-fg-muted)]">Keeper</span>
        <select
          class="rounded-[var(--r-1)] border border-[var(--color-border-subtle)] bg-[var(--color-bg-surface)] px-2 py-1"
          value=${selectedKeeper ?? ''}
          onChange=${(event: Event) => {
            const value = (event.currentTarget as HTMLSelectElement).value
            onSelectKeeper(value === '' ? null : value)
          }}
        >
          <option value="">Select a Keeper</option>
          ${keeperNames.map(keeperName => html`<option value=${keeperName}>${keeperName}</option>`)}
        </select>
      </label>
      ${selectedKeeper === null
        ? html`<div class="text-xs text-[var(--color-fg-muted)]">Select a Keeper to inspect its exact Skill surface.</div>`
        : loading
          ? html`<div class="text-xs text-[var(--color-fg-muted)]">Loading exact Skill receipts…</div>`
          : error
            ? html`<div class="text-xs text-[var(--color-status-bad)]">${error}</div>`
            : !effectiveSurface
              ? html`<div class="text-xs text-[var(--color-status-bad)]">
                  Server response omitted effective_keeper_surface
                </div>`
            : !activations
              ? html`<div class="text-xs text-[var(--color-status-bad)]">
                  Server response omitted skill_activations
                </div>`
            : html`
                <${SurfaceReceipt} surface=${effectiveSurface} />
                <${ActivationReceipt}
                  projection=${activations}
                />
              `}
    </div>
  `
}
