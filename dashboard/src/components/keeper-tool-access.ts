// MASC Dashboard — K1 · ToolAccess summary variant (read-only)
//
// Phase 2 spec (`design-system/preview/cb-group-h.jsx:KeeperToolAccess`)
// expects a compact <dl> of runtime / sandbox / network / auto_handoff /
// handoff_threshold / proactive_idle / mention targets,
// rendered as a quick-scan summary before the operator dives into the
// editable form. Production has all the data on `KeeperConfig` but only
// surfaces it through the editable `KeeperConfigPanel` form.
//
// This panel is intentionally read-only — mutations go through the existing
// editable form below it. The intent is "what are the current tool/exec
// settings for this keeper?" answered without scrolling.

import { html } from 'htm/preact'
import type { KeeperConfig } from '../types'

function ToolAccessRow({
  label, value,
}: {
  label: string
  value: unknown
}) {
  const display: unknown = value === null || value === undefined || value === '' ? '—' : value
  return html`
    <div class="grid grid-cols-[120px_1fr] items-baseline gap-3 py-1 v2-monitoring-row">
      <dt class="text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">${label}</dt>
      <dd class="font-mono text-xs text-text-strong">${display}</dd>
    </div>
  `
}

function mentionsLabel(targets: readonly string[]): string {
  if (targets.length === 0) return '—'
  return targets.map(t => `@${t}`).join(' · ')
}

export function KeeperToolAccessSummary({ config }: { config: KeeperConfig }) {
  const runtime = config.execution.selected_runtime_id || '—'
  const sandbox = config.sandbox_profile ?? '(unknown sandbox_profile)'
  const network = config.network_mode ?? '(unknown network_mode)'
  const handoff = `${config.handoff.auto ? 'on' : 'off'} · threshold ${config.handoff.threshold}`
  const idle = `${config.proactive.idle_sec}s${config.proactive.enabled ? '' : ' (disabled)'}`
  const mentions = mentionsLabel(config.workspace.mention_targets)
  const candidateCount = config.tools.resolved_allowlist.length
  const denylistCount = config.tools.tool_denylist.length

  return html`
    <section
      class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] p-4 v2-monitoring-panel"
      aria-label="툴 / 실행 접근 요약 (read-only)"
    >
      <header class="mb-2 flex items-baseline justify-between gap-2 v2-monitoring-toolbar">
        <h3 class="text-xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">
          툴 / 실행 접근 요약
        </h3>
        <span class="text-2xs text-text-disabled">read-only · 변경은 아래 편집 영역</span>
      </header>
      <dl class="grid grid-cols-1 gap-x-6 md:grid-cols-2 v2-monitoring-row">
        <${ToolAccessRow} label="runtime" value=${runtime} />
        <${ToolAccessRow} label="sandbox" value=${sandbox} />
        <${ToolAccessRow} label="network" value=${network} />
        <${ToolAccessRow} label="auto handoff" value=${handoff} />
        <${ToolAccessRow} label="proactive idle" value=${idle} />
        <${ToolAccessRow} label="mention targets" value=${mentions} />
        <${ToolAccessRow}
          label="candidate / deny"
          value=${`${candidateCount} candidate · ${denylistCount} deny`}
        />
      </dl>
    </section>
  `
}
