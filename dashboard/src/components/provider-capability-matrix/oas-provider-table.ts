// OasProviderTable — Runtime provider kind definitions from sec02 Table 1.

import { html } from 'htm/preact'
import {
  OAS_PROVIDER_CAPS,
  CAP_BOOLEAN_FIELDS,
} from './data'

function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(n % 1_000_000 === 0 ? 0 : 2)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(n % 1_000 === 0 ? 0 : 1)}K`
  return String(n)
}

export function OasProviderTable() {
  const isDirectApi = OAS_PROVIDER_CAPS.filter(p => p.usage === 'emit').length
  const isCliWrapper = OAS_PROVIDER_CAPS.filter(p => p.usage === 'strip').length

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-3 text-[10px] font-mono text-[var(--color-fg-muted)]">
        <span class="flex items-center gap-1">
          <span class="inline-block size-2 rounded-full bg-[#22c55e]"></span>
          Direct API (${isDirectApi})
        </span>
        <span class="flex items-center gap-1">
          <span class="inline-block size-2 rounded-full bg-[#eab308]"></span>
          CLI Wrapper (${isCliWrapper})
        </span>
      </div>

      <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
        <table class="w-full text-xs border-collapse">
          <thead>
            <tr class="bg-[var(--white-4)]">
              <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] sticky left-0 z-10 bg-[var(--white-4)] min-w-[100px]">Provider</th>
              <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] min-w-[90px]">Kind</th>
              <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-right font-medium text-[var(--color-fg-secondary)] min-w-[70px]">Max Context</th>
              <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-right font-medium text-[var(--color-fg-secondary)] min-w-[70px]">Max Output</th>
              ${CAP_BOOLEAN_FIELDS.map(f => html`
                <th key=${f.key} class="border-b border-[var(--color-border-default)] px-1.5 py-1.5 text-center font-medium text-[var(--color-fg-secondary)] min-w-[55px]">${f.label}</th>
              `)}
              <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-center font-medium text-[var(--color-fg-secondary)] min-w-[50px]">Usage</th>
            </tr>
          </thead>
          <tbody>
            ${OAS_PROVIDER_CAPS.map((prov, i) => {
              const isCli = prov.usage === 'strip'
              const rowBg = isCli
                ? 'bg-[rgba(234,179,8,0.04)]'
                : i % 2 === 0 ? '' : 'bg-[var(--white-2)]'
              return html`
                <tr key=${prov.id} class="${rowBg}">
                  <td class="sticky left-0 z-10 ${rowBg || 'bg-[var(--shell-rail-bg)]'} border-r border-[var(--color-border-default)] px-2 py-1.5 font-medium text-[var(--color-fg-primary)]">
                    <div class="flex items-center gap-1.5">
                      <span class="size-1.5 rounded-full ${isCli ? 'bg-[#eab308]' : 'bg-[#22c55e]'}"></span>
                      ${prov.label}
                    </div>
                  </td>
                  <td class="border-r border-[var(--color-border-default)] px-2 py-1.5 font-mono text-[10px] text-[var(--color-fg-muted)]">${prov.kind}</td>
                  <td class="border-r border-[var(--color-border-default)] px-2 py-1.5 text-right font-mono text-[var(--color-fg-secondary)]">${formatTokens(prov.maxContext)}</td>
                  <td class="border-r border-[var(--color-border-default)] px-2 py-1.5 text-right font-mono text-[var(--color-fg-secondary)]">${formatTokens(prov.maxOutput)}</td>
                  ${CAP_BOOLEAN_FIELDS.map(f => {
                    const val = prov[f.key]
                    return html`
                      <td key=${String(f.key)} class="border-r border-[var(--color-border-default)] px-1 py-0.5 text-center">
                        <span class="inline-block w-full rounded px-1 py-0.5 text-[10px] font-mono font-bold ${
                          val
                            ? 'bg-[rgba(34,197,94,0.15)] text-[#22c55e]'
                            : 'bg-[rgba(239,68,68,0.1)] text-[#ef4444]'
                        }">
                          ${val ? 'O' : 'X'}
                        </span>
                      </td>
                    `
                  })}
                  <td class="px-2 py-0.5 text-center">
                    <span class="inline-block rounded px-1.5 py-0.5 text-[10px] font-mono ${
                      isCli
                        ? 'bg-[rgba(234,179,8,0.15)] text-[#eab308]'
                        : 'bg-[rgba(34,197,94,0.15)] text-[#22c55e]'
                    }">
                      ${prov.usage}
                    </span>
                  </td>
                </tr>
              `
            })}
          </tbody>
        </table>
      </div>
    </div>
  `
}
