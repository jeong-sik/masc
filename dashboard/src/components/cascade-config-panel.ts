// CascadeConfigPanel — renders cascade.json profiles + health tracker state
// side-by-side so operators can see *why* a given provider is picked first.
//
// Consumes:
//   GET /api/v1/cascade/config  — profiles + per-candidate weight/health
//   GET /api/v1/cascade/health  — global health tracker snapshot
//
// Pattern mirrors RuntimeMonitor: managed async resource + manual refresh.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import {
  fetchCascadeConfig,
  fetchCascadeHealth,
  type CascadeCandidate,
  type CascadeConfigResponse,
  type CascadeHealthProvider,
  type CascadeHealthResponse,
  type CascadeProfile,
} from '../api/dashboard'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { ErrorState, LoadingState } from './common/feedback-state'
import { StatCell } from './common/stat-cell'
import { StatusChip } from './common/status-chip'
import { createManagedAsyncResource, type ManagedAsyncResource } from '../lib/async-state'

interface CascadeData {
  config: CascadeConfigResponse | null
  health: CascadeHealthResponse | null
}

async function loadCascadeData(resource: ManagedAsyncResource<CascadeData>) {
  await resource.load(async (signal) => {
    const [config, health] = await Promise.all([
      fetchCascadeConfig({ signal }),
      fetchCascadeHealth({ signal }),
    ])
    return { config, health }
  })
}

function fmtPct(value: number): string {
  if (Number.isNaN(value)) return '--'
  return `${(value * 100).toFixed(1)}%`
}

function candidateTone(c: CascadeCandidate): string {
  if (c.in_cooldown) return 'bad'
  if (c.effective_weight === 0) return 'bad'
  if (c.success_rate < 0.5) return 'bad'
  if (c.success_rate < 0.9) return 'warn'
  return 'ok'
}

function sourceLabel(source: CascadeProfile['source']): string {
  switch (source) {
    case 'named': return 'named'
    case 'default_fallback': return 'default'
    case 'hardcoded_defaults': return 'hardcoded'
  }
}

function sourceTone(source: CascadeProfile['source']): string {
  switch (source) {
    case 'named': return 'ok'
    case 'default_fallback': return 'warn'
    case 'hardcoded_defaults': return 'warn'
  }
}

function fmtCooldownExpiry(expiresAt: number | null): string {
  if (expiresAt == null) return '—'
  const delta = expiresAt - Date.now() / 1000
  if (delta <= 0) return '만료됨'
  if (delta < 60) return `${Math.ceil(delta)}초 후`
  return `${Math.ceil(delta / 60)}분 후`
}

function ProfileCard({ profile }: { profile: CascadeProfile }) {
  return html`
    <article class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] p-3">
      <header class="flex items-center gap-2 mb-2">
        <span class="font-semibold text-[var(--text-strong)]">${profile.name}</span>
        <${StatusChip} tone=${sourceTone(profile.source)}>
          ${sourceLabel(profile.source)}
        <//>
        <span class="text-xs text-[var(--text-muted)]">
          ${profile.candidates.length} candidate${profile.candidates.length === 1 ? '' : 's'}
        </span>
      </header>
      ${profile.candidates.length === 0
        ? html`<div class="text-xs text-[var(--text-muted)]">no candidates resolved</div>`
        : html`
          <ol class="flex flex-col gap-1 text-xs">
            ${profile.candidates.map((c, idx) => html`
              <li class="flex items-center gap-2 py-1 border-b border-[var(--card-border)] last:border-b-0">
                <span class="tabular-nums text-[var(--text-muted)] w-5">${idx + 1}.</span>
                <${StatusChip} tone=${candidateTone(c)}>
                  ${c.in_cooldown ? 'cooldown' : fmtPct(c.success_rate)}
                <//>
                <code class="flex-1 truncate text-[var(--text-strong)]">${c.model}</code>
                <span class="tabular-nums text-[var(--text-muted)]">
                  w ${c.config_weight}${c.effective_weight === c.config_weight ? '' : ` → ${c.effective_weight}`}
                </span>
              </li>
            `)}
          </ol>
        `}
    </article>
  `
}

function KeeperMapping({ config }: { config: CascadeConfigResponse }) {
  const mapping = config.keeper_profiles
  if (mapping.length === 0) {
    return html`<${EmptyState}>활성 keeper 없음<//>`
  }
  return html`
    <table class="w-full text-xs">
      <thead>
        <tr class="text-[var(--text-muted)] border-b border-[var(--card-border)]">
          <th class="text-left py-1">Keeper</th>
          <th class="text-left py-1">Cascade Name</th>
          <th class="text-left py-1">Canonical</th>
        </tr>
      </thead>
      <tbody>
        ${mapping.map(m => html`
          <tr class="border-b border-[var(--card-border)] last:border-b-0">
            <td class="py-1 font-semibold text-[var(--text-strong)]">${m.keeper}</td>
            <td class="py-1"><code>${m.cascade_name}</code></td>
            <td class="py-1">
              ${m.cascade_name === m.canonical
                ? html`<span class="text-[var(--text-muted)]">—</span>`
                : html`<code>${m.canonical}</code>`}
            </td>
          </tr>
        `)}
      </tbody>
    </table>
  `
}

function HealthTable({ health }: { health: CascadeHealthResponse }) {
  if (health.providers.length === 0) {
    return html`<${EmptyState}>아직 기록된 provider 이벤트가 없습니다.<//>`
  }
  return html`
    <table class="w-full text-xs">
      <thead>
        <tr class="text-[var(--text-muted)] border-b border-[var(--card-border)]">
          <th class="text-left py-1">Provider</th>
          <th class="text-right py-1">Success</th>
          <th class="text-right py-1">Consec. fail</th>
          <th class="text-right py-1">Events</th>
          <th class="text-right py-1">Cooldown</th>
        </tr>
      </thead>
      <tbody>
        ${health.providers.map((p: CascadeHealthProvider) => html`
          <tr class="border-b border-[var(--card-border)] last:border-b-0">
            <td class="py-1"><code class="text-[var(--text-strong)]">${p.provider_key}</code></td>
            <td class="py-1 text-right tabular-nums">${fmtPct(p.success_rate)}</td>
            <td class="py-1 text-right tabular-nums">${p.consecutive_failures}</td>
            <td class="py-1 text-right tabular-nums">${p.events_in_window}</td>
            <td class="py-1 text-right">
              ${p.in_cooldown
                ? html`<${StatusChip} tone="bad">${fmtCooldownExpiry(p.cooldown_expires_at)}<//>`
                : html`<span class="text-[var(--text-muted)]">—</span>`}
            </td>
          </tr>
        `)}
      </tbody>
    </table>
  `
}

export function CascadeConfigPanel() {
  const resourceRef = useRef<ManagedAsyncResource<CascadeData> | null>(null)
  if (resourceRef.current === null) {
    resourceRef.current = createManagedAsyncResource<CascadeData>()
  }
  const resource = resourceRef.current

  useEffect(() => {
    void loadCascadeData(resource)
    return () => { resource.cancel() }
  }, [resource])

  const current = resource.state.value
  const config = current.data?.config ?? null
  const health = current.data?.health ?? null

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center gap-3 flex-wrap">
        <button
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-1 text-xs text-[var(--text-strong)] hover:bg-[var(--bg-panel-hover)]"
          onClick=${() => void loadCascadeData(resource)}
        >
          새로고침
        </button>
        ${current.loading ? html`<span class="text-xs text-[var(--text-muted)]">로딩 중...</span>` : null}
        ${config?.updated_at
          ? html`<span class="text-xs text-[var(--text-muted)]">config · ${config.updated_at}</span>`
          : null}
      </div>

      ${current.error ? html`<${ErrorState} message=${current.error} />` : null}

      ${current.loading && !config && !health
        ? html`<${LoadingState}>cascade snapshot 불러오는 중...<//>`
        : null}

      <${Card} title="Cascade Profiles">
        ${config
          ? html`
            <div class="grid grid-cols-2 gap-3 mb-3">
              <${StatCell}
                label="Profiles"
                value=${config.profiles.length}
                detail=${config.config_path ?? 'config 없음'}
              />
              <${StatCell}
                label="Keepers"
                value=${config.keeper_profiles.length}
                detail="cascade_name 등록됨"
              />
            </div>
            <div class="grid gap-3 md:grid-cols-2">
              ${config.profiles.map(p => html`<${ProfileCard} profile=${p} />`)}
            </div>
          `
          : null}
      <//>

      <${Card} title="Keeper → Cascade Mapping">
        ${config ? html`<${KeeperMapping} config=${config} />` : null}
      <//>

      <${Card} title="Health Tracker">
        ${health
          ? html`
            <div class="grid grid-cols-3 gap-3 mb-3">
              <${StatCell}
                label="Window"
                value=${`${health.window_sec}s`}
                detail=${`${health.providers.length} tracked`}
              />
              <${StatCell}
                label="Cooldown Threshold"
                value=${health.cooldown_threshold}
                detail="연속 실패"
              />
              <${StatCell}
                label="Cooldown"
                value=${`${health.cooldown_sec}s`}
                detail="활성 시 차단 시간"
              />
            </div>
            <${HealthTable} health=${health} />
          `
          : null}
      <//>
    </div>
  `
}
