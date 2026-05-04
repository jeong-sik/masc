// OasProviderTable — Runtime provider kind definitions from sec02 Table 1.

import { html } from 'htm/preact'
import { StatusDot } from '../common/status-dot'
import { formatTokens } from '../../lib/format-number'
import {
  OAS_PROVIDER_CAPS,
  CAP_BOOLEAN_FIELDS,
} from './data'

const MAX_CONTEXT = Math.max(1, ...OAS_PROVIDER_CAPS.map(p => p.maxContext))

function ProviderContextBar({ maxContext }: { maxContext: number }) {
  const pct = (maxContext / MAX_CONTEXT) * 100
  return html`
    <div class="w-full h-1 rounded-[var(--r-0)] bg-[var(--color-bg-elevated)] overflow-hidden">
      <div class="h-full rounded-[var(--r-0)]" style="width: ${pct.toFixed(1)}%; background: var(--color-accent-fg); opacity: 0.6"></div>
    </div>
  `
}

function CapabilityCoverageStrip() {
  const total = OAS_PROVIDER_CAPS.length * CAP_BOOLEAN_FIELDS.length
  const enabled = OAS_PROVIDER_CAPS.reduce(
    (sum, prov) => sum + CAP_BOOLEAN_FIELDS.filter(f => prov[f.key]).length, 0,
  )
  const pct = total > 0 ? (enabled / total * 100) : 0

  return html`
    <div class="flex items-center gap-3">
      <span class="text-2xs text-[var(--color-fg-muted)]">기능 커버리지</span>
      <div class="flex-1 h-2 rounded-[var(--r-0)] bg-[var(--color-bg-elevated)] overflow-hidden">
        <div class="h-full rounded-[var(--r-0)]" style="width: ${pct.toFixed(1)}%; background: var(--color-status-ok); opacity: 0.6"></div>
      </div>
      <span class="text-2xs font-mono text-[var(--color-fg-muted)]">${enabled}/${total} (${pct.toFixed(0)}%)</span>
    </div>
  `
}

export function OasProviderTable() {
  const isDirectApi = OAS_PROVIDER_CAPS.filter(p => p.usage === 'emit').length
  const isCliWrapper = OAS_PROVIDER_CAPS.filter(p => p.usage === 'strip').length

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-3 t-caption">
        <span class="flex items-center gap-1">
          <${StatusDot} size="sm" class="bg-[var(--color-status-ok)]" />
          Direct API (${isDirectApi})
        </span>
        <span class="flex items-center gap-1">
          <${StatusDot} size="sm" class="bg-[var(--color-status-warn)]" />
          CLI Wrapper (${isCliWrapper})
        </span>
      </div>

      <${CapabilityCoverageStrip} />

      <div class="pm-scroll">
        <table class="pm-table">
          <thead class="pm-thead">
            <tr>
              <th class="pm-th pm-th--sticky min-w-[100px]">Provider</th>
              <th class="pm-th min-w-[90px]">Kind</th>
              <th class="pm-th pm-th--right min-w-[70px]">Max Context</th>
              <th class="pm-th pm-th--right min-w-[70px]">Max Output</th>
              ${CAP_BOOLEAN_FIELDS.map(f => html`
                <th key=${f.key} class="pm-th pm-th--center min-w-[55px]">${f.label}</th>
              `)}
              <th class="pm-th pm-th--center min-w-[50px]">Usage</th>
            </tr>
          </thead>
          <tbody>
            ${OAS_PROVIDER_CAPS.map((prov) => {
              const isCli = prov.usage === 'strip'
              const enabledCount = CAP_BOOLEAN_FIELDS.filter(f => prov[f.key]).length
              const coveragePct = CAP_BOOLEAN_FIELDS.length > 0 ? (enabledCount / CAP_BOOLEAN_FIELDS.length * 100) : 0
              return html`
                <tr key=${prov.id} class="pm-row-alt ${isCli ? 'pm-row--cli' : ''}">
                  <td class="pm-td pm-td--sticky">
                    <div class="flex items-center gap-1.5">
                      <${StatusDot} size="xs" class=${isCli ? 'bg-[var(--color-status-warn)]' : 'bg-[var(--color-status-ok)]'} />
                      ${prov.label}
                    </div>
                  </td>
                  <td class="pm-td pm-td--right-border pm-td--mono">${prov.kind}</td>
                  <td class="pm-td pm-td--right-border">
                    <div class="flex flex-col gap-0.5">
                      <span class="pm-td--mono text-right">${formatTokens(prov.maxContext)}</span>
                      <${ProviderContextBar} maxContext=${prov.maxContext} />
                    </div>
                  </td>
                  <td class="pm-td pm-td--right-border pm-td--mono pm-td--right">${formatTokens(prov.maxOutput)}</td>
                  ${CAP_BOOLEAN_FIELDS.map(f => {
                    const val = prov[f.key]
                    return html`
                      <td key=${String(f.key)} class="pm-td pm-td--right-border pm-td--center">
                        <span class="pm-cell-badge ${val ? 'chip sm is-ok' : 'chip sm is-err'}">
                          ${val ? 'O' : 'X'}
                        </span>
                      </td>
                    `
                  })}
                  <td class="pm-td pm-td--center">
                    <span class="chip sm ${isCli ? 'is-warn' : 'is-ok'}">
                      ${prov.usage}
                    </span>
                    <div class="mt-0.5">
                      <div class="w-full h-0.5 rounded-[var(--r-0)] bg-[var(--color-bg-elevated)] overflow-hidden">
                        <div class="h-full rounded-[var(--r-0)]" style="width: ${coveragePct}%; background: var(--color-status-ok); opacity: 0.4"></div>
                      </div>
                    </div>
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
