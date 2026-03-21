// Keeper config panel — read-only structured config viewer.
// Fetches /api/v1/keepers/:name/config and renders grouped sections.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { fetchKeeperConfig } from '../api/dashboard'
import type { KeeperConfig } from '../types'
import { formatTokens } from './keeper-detail-panels'

// ── State ────────────────────────────────────────────────

type ConfigState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; config: KeeperConfig }
  | { status: 'error'; message: string }

const configState = signal<ConfigState>({ status: 'idle' })
const configKeeperName = signal<string>('')

export async function loadKeeperConfig(name: string): Promise<void> {
  if (configKeeperName.value === name && configState.value.status === 'loaded') return
  configKeeperName.value = name
  configState.value = { status: 'loading' }
  try {
    const config = await fetchKeeperConfig(name)
    configState.value = { status: 'loaded', config }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Failed to load config'
    configState.value = { status: 'error', message }
  }
}

export function resetKeeperConfig(): void {
  configState.value = { status: 'idle' }
  configKeeperName.value = ''
}

// ── Helpers ──────────────────────────────────────────────

function ConfigRow({ label, value }: { label: string; value: string }) {
  return html`
    <div class="keeper-signal-row">
      <span>${label}</span>
      <strong>${value}</strong>
    </div>
  `
}

function SectionHeader({ title }: { title: string }) {
  return html`
    <div style="font-size:12px; font-weight:700; color:#a78bfa; text-transform:uppercase; letter-spacing:1px; margin-top:16px; margin-bottom:8px; padding-bottom:4px; border-bottom:1px solid rgba(167,139,250,0.2);">
      ${title}
    </div>
  `
}

function BoolBadge({ value }: { value: boolean }) {
  const color = value ? '#4ade80' : '#6b7280'
  const text = value ? 'on' : 'off'
  return html`<span style="color:${color}; font-weight:600;">${text}</span>`
}

function ModelList({ models }: { models: string[] }) {
  if (models.length === 0) return html`<span style="color:#666;">none</span>`
  return html`
    <div style="display:flex; flex-wrap:wrap; gap:4px;">
      ${models.map(m => html`<span class="pill" style="font-size:11px;">${m}</span>`)}
    </div>
  `
}

function LongText({ text }: { text: string }) {
  if (!text || text.trim() === '') return html`<span style="color:#666;">--</span>`
  const truncated = text.length > 200 ? text.slice(0, 200) + '...' : text
  return html`<div style="font-size:12px; color:#ccc; white-space:pre-wrap; max-height:120px; overflow-y:auto; background:rgba(255,255,255,0.02); padding:6px 8px; border-radius:4px; margin-top:4px;">${truncated}</div>`
}

// ── Main component ───────────────────────────────────────

export function KeeperConfigPanel({ keeperName }: { keeperName: string }) {
  const state = configState.value

  // Trigger load on first render or name change
  if (configKeeperName.value !== keeperName || state.status === 'idle') {
    void loadKeeperConfig(keeperName)
  }

  if (state.status === 'loading') {
    return html`<div class="keeper-signal-list"><div style="color:#888; font-size:13px; padding:12px 0;">Loading config...</div></div>`
  }

  if (state.status === 'error') {
    return html`<div class="keeper-signal-list"><div style="color:#ef4444; font-size:13px; padding:12px 0;">${state.message}</div></div>`
  }

  if (state.status !== 'loaded') return null

  const c = state.config

  return html`
    <div class="keeper-signal-list">

      ${'' /* --- Execution --- */}
      <${SectionHeader} title="Execution" />
      <${ConfigRow} label="Active model" value=${c.execution.active_model || '--'} />
      <${ConfigRow} label="Policy mode" value=${c.execution.policy_mode || '--'} />
      <${ConfigRow} label="Shell mode" value=${c.execution.policy_shell_mode || '--'} />
      <div class="keeper-signal-row">
        <span>Verify</span>
        <strong><${BoolBadge} value=${c.execution.verify} /></strong>
      </div>
      <div style="margin-top:6px;">
        <div style="font-size:11px; color:#888; margin-bottom:4px;">Models</div>
        <${ModelList} models=${c.execution.models} />
      </div>
      ${c.execution.allowed_models.length > 0 ? html`
        <div style="margin-top:6px;">
          <div style="font-size:11px; color:#888; margin-bottom:4px;">Allowed models</div>
          <${ModelList} models=${c.execution.allowed_models} />
        </div>
      ` : null}

      ${'' /* --- Compaction --- */}
      <${SectionHeader} title="Compaction" />
      <${ConfigRow} label="Profile" value=${c.compaction.profile || '--'} />
      <${ConfigRow} label="Ratio gate" value=${(c.compaction.ratio_gate * 100).toFixed(0) + '%'} />
      <${ConfigRow} label="Message gate" value=${String(c.compaction.message_gate)} />
      <${ConfigRow} label="Token gate" value=${formatTokens(c.compaction.token_gate)} />
      <${ConfigRow} label="Cooldown" value=${c.compaction.cooldown_sec + 's'} />

      ${'' /* --- Proactive --- */}
      <${SectionHeader} title="Proactive" />
      <div class="keeper-signal-row">
        <span>Enabled</span>
        <strong><${BoolBadge} value=${c.proactive.enabled} /></strong>
      </div>
      <${ConfigRow} label="Idle trigger" value=${c.proactive.idle_sec + 's'} />
      <${ConfigRow} label="Cooldown" value=${c.proactive.cooldown_sec + 's'} />

      ${'' /* --- Drift --- */}
      <${SectionHeader} title="Drift" />
      <div class="keeper-signal-row">
        <span>Enabled</span>
        <strong><${BoolBadge} value=${c.drift.enabled} /></strong>
      </div>
      <${ConfigRow} label="Min turn gap" value=${String(c.drift.min_turn_gap)} />
      <${ConfigRow} label="Count total" value=${String(c.drift.count_total)} />
      ${c.drift.last_reason ? html`<${ConfigRow} label="Last reason" value=${c.drift.last_reason} />` : null}

      ${'' /* --- Initiative --- */}
      <${SectionHeader} title="Initiative" />
      <div class="keeper-signal-row">
        <span>Enabled</span>
        <strong><${BoolBadge} value=${c.initiative.enabled} /></strong>
      </div>
      <${ConfigRow} label="Scope" value=${c.initiative.scope || '--'} />
      <${ConfigRow} label="Idle trigger" value=${c.initiative.idle_sec + 's'} />
      <${ConfigRow} label="Cooldown" value=${c.initiative.cooldown_sec + 's'} />
      <${ConfigRow} label="Context mode" value=${c.initiative.context_mode || '--'} />

      ${'' /* --- Handoff --- */}
      <${SectionHeader} title="Handoff" />
      <div class="keeper-signal-row">
        <span>Auto</span>
        <strong><${BoolBadge} value=${c.handoff.auto} /></strong>
      </div>
      <${ConfigRow} label="Threshold" value=${(c.handoff.threshold * 100).toFixed(0) + '%'} />
      <${ConfigRow} label="Cooldown" value=${c.handoff.cooldown_sec + 's'} />

      ${'' /* --- Metrics snapshot --- */}
      <${SectionHeader} title="Metrics" />
      <${ConfigRow} label="Generation" value=${String(c.metrics.generation)} />
      <${ConfigRow} label="Total turns" value=${String(c.metrics.total_turns)} />
      <${ConfigRow} label="Total tokens" value=${formatTokens(c.metrics.total_tokens)} />
      <${ConfigRow} label="Total cost" value=${'$' + c.metrics.total_cost_usd.toFixed(4)} />
      <${ConfigRow} label="Compactions" value=${String(c.metrics.compaction_count)} />

      ${'' /* --- Prompt / Goals --- */}
      <${SectionHeader} title="Prompt" />
      <div style="font-size:11px; color:#888; margin-bottom:2px;">Goal</div>
      <${LongText} text=${c.prompt.goal} />
      ${c.prompt.short_goal ? html`
        <div style="font-size:11px; color:#888; margin-top:8px; margin-bottom:2px;">Short-term goal</div>
        <${LongText} text=${c.prompt.short_goal} />
      ` : null}
      ${c.prompt.mid_goal ? html`
        <div style="font-size:11px; color:#888; margin-top:8px; margin-bottom:2px;">Mid-term goal</div>
        <${LongText} text=${c.prompt.mid_goal} />
      ` : null}
      ${c.prompt.long_goal ? html`
        <div style="font-size:11px; color:#888; margin-top:8px; margin-bottom:2px;">Long-term goal</div>
        <${LongText} text=${c.prompt.long_goal} />
      ` : null}
      ${c.prompt.soul_profile ? html`
        <div style="font-size:11px; color:#888; margin-top:8px; margin-bottom:2px;">Soul profile</div>
        <${LongText} text=${c.prompt.soul_profile} />
      ` : null}
      ${c.prompt.instructions ? html`
        <div style="font-size:11px; color:#888; margin-top:8px; margin-bottom:2px;">Instructions</div>
        <${LongText} text=${c.prompt.instructions} />
      ` : null}
    </div>
  `
}
