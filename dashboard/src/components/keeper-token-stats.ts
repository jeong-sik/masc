// MASC Dashboard — K1 · TokenStats variant (cross-keeper aggregate)
//
// Phase 2 spec (`design-system/preview/cb-group-h.jsx:KeeperTokenStats`)
// asks for a fleet-wide token table. Production exposes per-keeper trend
// only via `TokenTrendChart`. This panel reads the existing `keepers`
// signal (which already carries `total_tokens` / `total_turns`) and
// renders a sorted aggregate so the operator can see relative load
// without opening each keeper detail page.
//
// Decision: derive from `keepers` signal (no new fetch). In/out split
// is omitted because per-keeper in/out values live behind separate
// `KeeperConfigPanel` fetches; the spec's primary intent is rank +
// distribution which `total_tokens` covers.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { keepers, selectedKeeperFilter } from '../store'

interface KeeperTokenRow {
  name: string
  displayName: string
  emoji: string
  turns: number
  tokens: number
}

const rows = computed<KeeperTokenRow[]>(() => {
  const filter = selectedKeeperFilter.value
  const isAll = filter.size === 0
  return keepers.value
    .filter(k => isAll || filter.has(k.name))
    .map(k => ({
      name: k.name,
      displayName: k.koreanName ?? k.name,
      emoji: k.emoji ?? '',
      turns: k.total_turns ?? k.turn_count ?? 0,
      tokens: k.total_tokens ?? 0,
    }))
    .filter(r => r.tokens > 0 || r.turns > 0)
    .sort((a, b) => b.tokens - a.tokens)
})

export function KeeperTokenStats() {
  const data = rows.value

  if (data.length === 0) {
    return html`
      <section
        class="v2-monitoring-panel monitor-muted-panel p-4 text-xs text-[var(--color-fg-muted)]"
        aria-label="키퍼 토큰 사용량 집계"
      >
        <header class="mb-1 text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
          키퍼 토큰 사용량 (집계)
        </header>
        <p>아직 토큰을 소비한 키퍼가 없습니다.</p>
      </section>
    `
  }

  const totalTurns = data.reduce((sum, r) => sum + r.turns, 0)
  const totalTokens = data.reduce((sum, r) => sum + r.tokens, 0)
  const maxTokens = Math.max(1, ...data.map(r => r.tokens))

  return html`
    <section
      class="v2-monitoring-panel monitor-muted-panel flex flex-col gap-3 p-4"
      aria-label="키퍼 토큰 사용량 집계"
    >
      <header class="flex flex-wrap items-baseline justify-between gap-2">
        <h3 class="text-xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
          키퍼 토큰 사용량 (집계)
        </h3>
        <span class="text-2xs text-[var(--color-fg-disabled)]">
          ${data.length} keepers · 총 ${totalTokens.toLocaleString()} tok / ${totalTurns.toLocaleString()} turns
        </span>
      </header>
      <div class="overflow-x-auto">
        <table class="v2-monitoring-table w-full font-mono text-xs">
          <thead>
            <tr class="border-b border-[var(--color-border-default)] text-left text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
              <th class="py-1 pr-2">keeper</th>
              <th class="py-1 px-2 text-right">turns</th>
              <th class="py-1 px-2 text-right">total tokens</th>
              <th class="py-1 pl-2 min-w-[120px]">distribution</th>
            </tr>
          </thead>
          <tbody>
            ${data.map(r => html`
              <tr
                key=${r.name}
                class="v2-monitoring-row border-b border-[var(--color-border-default)]/40"
              >
                <td class="py-1 pr-2">
                  <span aria-hidden="true">${r.emoji}</span>
                  <span class="ml-1">${r.displayName}</span>
                </td>
                <td class="py-1 px-2 text-right">${r.turns.toLocaleString()}</td>
                <td class="py-1 px-2 text-right">${r.tokens.toLocaleString()}</td>
                <td class="py-1 pl-2">
                  <div
                    class="h-1.5 rounded-[var(--r-0)] bg-[var(--color-bg-surface)]"
                    role="presentation"
                  >
                    <div
                      class="h-full rounded-[var(--r-0)] bg-[var(--color-accent-fg)]"
                      style=${`width: ${((r.tokens / maxTokens) * 100).toFixed(1)}%`}
                    ></div>
                  </div>
                </td>
              </tr>
            `)}
          </tbody>
          <tfoot>
            <tr class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
              <td class="pt-2 pr-2">total</td>
              <td class="pt-2 px-2 text-right">${totalTurns.toLocaleString()}</td>
              <td class="pt-2 px-2 text-right">${totalTokens.toLocaleString()}</td>
              <td class="pt-2 pl-2">${data.length} keepers</td>
            </tr>
          </tfoot>
        </table>
      </div>
    </section>
  `
}
