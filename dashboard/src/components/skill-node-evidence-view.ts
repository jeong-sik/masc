import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { SkillExecutorSettlement } from '../api/dashboard-skills'

function executionOrigin(origin: SkillExecutorSettlement['execution_origin']): string {
  switch (origin) {
    case 'fresh_dispatch': return 'Fresh dispatch'
    case 'retained_completion': return 'Retained completion'
    case 'dispatch_refused': return 'Dispatch refused'
  }
}

function payload(value: unknown): string {
  return value === undefined ? 'Unavailable' : JSON.stringify(value, null, 2)
}

function NodeSettlement({ node, peak }: { node: SkillExecutorSettlement; peak: number }) {
  const [open, setOpen] = useState(false)
  const color = {
    completed: 'var(--color-status-ok)',
    failed: 'var(--color-status-err)',
    deferred: 'var(--color-status-warn)',
  }[node.result.disposition]
  return html`
    <details class="min-w-0 rounded border border-[var(--color-border-default)] p-2"
      onToggle=${(event: Event) => setOpen((event.currentTarget as HTMLDetailsElement).open)}>
      <summary class="cursor-pointer break-words">
        <strong>${node.node_id}</strong> · ${node.tool_name} · ${node.result.disposition}
        · ${node.result.duration_ms}ms
      </summary>
      <div class="mt-2 h-2 overflow-hidden rounded bg-[var(--color-border-default)]" aria-hidden="true">
        <div class="h-full" style=${{ width: `${peak > 0 ? node.result.duration_ms / peak * 100 : 0}%`, backgroundColor: color }} />
      </div>
      <div class="mt-1 text-3xs ss-muted">
        ${executionOrigin(node.execution_origin)} · batch ${node.schedule.batch_index}
        · ${node.schedule.execution_mode} · planned ${node.schedule.planned_index}
      </div>
      ${open ? html`
        <div class="mt-2 space-y-2 text-3xs">
          <div class="mono break-all">Execution ${node.execution_id}</div>
          <div>Result bytes: ${node.result_bytes} · ${node.truncated_to === null
            ? 'No truncation recorded'
            : `Truncated to ${node.truncated_to} bytes`}</div>
          ${node.deferred_kind === null ? null : html`<div>Deferred: ${node.deferred_kind}</div>`}
          ${node.failure_effect_disposition === null ? null : html`<div>Effect evidence: ${node.failure_effect_disposition}</div>`}
          <div class="grid min-w-0 gap-2 lg:grid-cols-2">
            <div class="min-w-0"><strong>Observed input</strong>
              <pre class="max-h-64 overflow-auto whitespace-pre-wrap break-words rounded bg-[var(--color-surface-raised)] p-2">${payload(node.input)}</pre>
            </div>
            <div class="min-w-0"><strong>Observed result</strong>
              <pre class="max-h-64 overflow-auto whitespace-pre-wrap break-words rounded bg-[var(--color-surface-raised)] p-2">${payload(node.result)}</pre>
            </div>
          </div>
        </div>
      ` : null}
    </details>
  `
}

export function SkillNodeEvidenceView({ nodes }: { nodes: readonly SkillExecutorSettlement[] }) {
  const peak = nodes.reduce((maximum, node) => Math.max(maximum, node.result.duration_ms), 0)
  return html`
    <section class="mt-3 min-w-0 space-y-2" aria-label="Observed composition nodes">
      <strong>Observed nodes · ${nodes.length} settlements</strong>
      <div class="ss-muted text-3xs">Stored executor results · shared 0 → ${peak}ms scale.
        Execution origin and recorded scheduling are separate from queue, dependency and model time.
        Expand a node for its actual input, result and truncation evidence.</div>
      ${nodes.length === 0 ? html`<div class="ss-muted">No node settlements retained.</div>` : null}
      ${nodes.map(node => html`<${NodeSettlement}
        key=${JSON.stringify([node.node_id, node.execution_id])} node=${node} peak=${peak} />`)}
    </section>
  `
}
