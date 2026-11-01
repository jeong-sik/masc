import { html } from 'htm/preact'
import type { SkillSurfaceProfile } from '../api/dashboard-skills'

export function SkillFlowView({ profile }: { profile: SkillSurfaceProfile }) {
  const flow = profile.flow
  if (!flow) {
    return html`<div class="ss-muted">Instruction body → keeper_skill → model-orchestrated tools</div>`
  }
  return html`
    <div class="mt-2 flex items-stretch gap-2 overflow-x-auto pb-2" data-testid="skill-flow">
      ${flow.batches.map((batch, index) => html`
        <div class="flex items-center gap-2" key=${batch.index}>
          <div class="min-w-48 rounded border border-[var(--color-border)] bg-[var(--color-surface-raised)] p-2">
            <div class="mb-2 text-3xs uppercase tracking-wide text-[var(--color-text-muted)]">
              batch ${batch.index} · ${batch.execution_mode}
            </div>
            <div class="space-y-1">
              ${batch.node_ids.map(nodeId => {
                const node = flow.nodes.find(candidate => candidate.id === nodeId)
                if (!node) return null
                const dependency = node.dependencies.length === 0
                  ? 'root'
                  : node.dependencies.map(edge => `${edge.node_id}:${edge.kind}`).join(', ')
                return html`
                  <div class="rounded border border-[var(--color-border-subtle)] px-2 py-1" key=${node.id}>
                    <div class="font-semibold">${node.id}</div>
                    <div class="mono text-3xs">${node.tool_name}</div>
                    <div class="ss-muted text-3xs">depends ${dependency}</div>
                  </div>
                `
              })}
            </div>
          </div>
          ${index < flow.batches.length - 1 ? html`<span class="text-lg text-[var(--color-accent)]">→</span>` : null}
        </div>
      `)}
    </div>
  `
}

