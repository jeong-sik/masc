// OasProviderTable — Runtime provider kind definitions from sec02 Table 1.

import { html } from 'htm/preact'
import { StatusDot } from '../common/status-dot'
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
            ${OAS_PROVIDER_CAPS.map((prov, i) => {
              const isCli = prov.usage === 'strip'
              return html`
                <tr key=${prov.id} class="pm-row-alt ${isCli ? 'pm-row--cli' : ''}">
                  <td class="pm-th--sticky pm-td">
                    <div class="flex items-center gap-1.5">
                      <${StatusDot} size="xs" class=${isCli ? 'bg-[var(--color-status-warn)]' : 'bg-[var(--color-status-ok)]'} />
                      ${prov.label}
                    </div>
                  </td>
                  <td class="pm-td pm-td--right-border pm-td--mono">${prov.kind}</td>
                  <td class="pm-td pm-td--right-border pm-td--mono">${formatTokens(prov.maxContext)}</td>
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
