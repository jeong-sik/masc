import { html } from 'htm/preact'
import { TimeAgo } from './common/time-ago'
import type { Keeper } from '../types'

export function KeeperActivitySummary({ keeper }: { keeper: Keeper }) {
  const hasActivity =
    keeper.last_heartbeat ||
    keeper.last_speech_act ||
    keeper.recent_output_preview ||
    keeper.memory_recent_note ||
    (keeper.k2k_count ?? 0) > 0

  if (!hasActivity) return null

  return html`
    <div class="flex flex-wrap items-start gap-3 px-1">
      ${keeper.last_heartbeat
        ? html`<span class="inline-flex items-center gap-1.5 text-2xs text-[var(--color-fg-muted)] px-2.5 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
            하트비트 <${TimeAgo} timestamp=${keeper.last_heartbeat} />
          </span>`
        : null}
      ${keeper.last_speech_act
        ? html`<span class="inline-flex items-center gap-1.5 text-2xs text-[var(--color-fg-muted)] px-2.5 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
            최근 <span class="font-mono text-[var(--color-fg-primary)]">${keeper.last_speech_act}</span>
          </span>`
        : null}
      ${keeper.social_model_recognized === false
        ? html`<span class="inline-flex items-center gap-1.5 text-2xs text-[var(--color-status-warn)] px-2.5 py-1 rounded-[var(--r-1)] border border-[var(--warn-24)] bg-[var(--warn-8)]">
            대화 모델
            ${keeper.configured_social_model
              ? html`<span class="font-mono text-[var(--color-fg-primary)]">${keeper.configured_social_model}</span>`
              : null}
            ${keeper.configured_social_model && keeper.social_model_fallback
              ? html`<span>→</span>`
              : null}
            ${keeper.social_model_fallback
              ? html`<span class="font-mono text-[var(--color-fg-primary)]">${keeper.social_model_fallback}</span>`
              : null}
          </span>`
        : null}
      ${(keeper.k2k_count ?? 0) > 0
        ? html`<span class="inline-flex items-center gap-1 text-2xs px-2.5 py-1 rounded-[var(--r-1)] bg-[var(--info-soft)] border border-[var(--info-border)] text-[var(--color-fg-muted)]">
            K2K <span class="font-mono font-medium text-[var(--info-fg)]">${keeper.k2k_count}</span>
          </span>`
        : null}
      ${keeper.memory_recent_note
        ? html`<span class="text-2xs text-[var(--color-fg-muted)] px-2.5 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] truncate max-w-90" title=${keeper.memory_recent_note}>${keeper.memory_recent_note}</span>`
        : null}
    </div>
    ${keeper.recent_output_preview
      ? html`<div class="py-2 px-3 rounded-[var(--r-1)] bg-[var(--accent-6)] border border-[var(--accent-12)] text-xs text-[var(--color-fg-primary)] leading-relaxed">
          <div class="line-clamp-2">${keeper.recent_output_preview}</div>
        </div>`
      : null}
  `
}
