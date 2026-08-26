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

function originLabel(origin: DashboardSkillActivation['origin']): string {
  switch (origin.kind) {
    case 'task_instruction':
      return `Task instruction · ${origin.task_id}`
    case 'session_instruction':
      return 'Session instruction'
    case 'task_composition':
      return `Task composition · ${origin.task_id} · ${origin.tool_name}`
    case 'session_composition':
      return `Session composition · ${origin.tool_name}`
  }
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
      <div class="grid gap-1">
        ${references.length === 0
          ? html`<span class="text-xs text-[var(--color-fg-muted)]">No readable Skills</span>`
          : references.map(reference => html`
              <code class="text-3xs break-all">${referenceLabel(reference)}</code>
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

function ActivationReceipt({ projection }: { projection: DashboardSkillActivationProjection }) {
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
  return html`
    <div class="grid gap-2" data-testid="skill-activation-ledger">
      <div class="text-xs text-[var(--color-fg-muted)]">
        session ${projection.ledger.session_id} · ${projection.ledger.activations.length} activations
      </div>
      ${projection.ledger.activations.length === 0
        ? html`<span class="text-xs text-[var(--color-fg-muted)]">No activations recorded</span>`
        : projection.ledger.activations.map(activation => html`
            <div class="rounded-[var(--r-1)] border border-[var(--color-border-subtle)] p-2 grid gap-1">
              <code class="text-3xs break-all">${activationReferenceLabel(activation)}</code>
              <span class="text-3xs">${originLabel(activation.origin)}</span>
              <code class="text-3xs break-all text-[var(--color-fg-muted)]">
                snapshot ${activation.snapshot_revision} · turn ${activation.turn_ref}
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
                <${ActivationReceipt} projection=${activations} />
              `}
    </div>
  `
}
