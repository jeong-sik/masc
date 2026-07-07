// Tools main component — orchestrates inventory and executor views

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { SectionCard } from '../common/card'
import { ToolMetrics } from '../tool-metrics'
import {
  toolsData,
  toolsLoading,
  toolsError,
  loadTools,
} from './tool-state'
import { FullInventoryView } from './tool-full-inventory'
import { PromptRegistryPanel } from './prompt-registry-panel'
import { ConfigResolutionPanel } from './config-resolution-panel'
import { ActionButton } from '../common/button'
import { ToolExecutor } from '../tool-executor/tool-executor'
import { formatElapsedCompact } from '../../lib/format-time'
import { sourceHealthClass, coverageGapDisplay } from '../common/source-health'
import { ScheduledAutomationPanel } from './scheduled-automation-panel'
import { KeeperWaitingInventoryPanel } from './keeper-waiting-inventory-panel'

type ToolsView = 'inventory' | 'executor'
const activeView = signal<ToolsView>('inventory')

function sourceFreshnessLabel(latestAge: number | null | undefined): string {
  if (typeof latestAge !== 'number' || !Number.isFinite(latestAge)) {
    return 'latest n/a'
  }
  return `latest ${formatElapsedCompact(latestAge)}`
}

export function Tools() {
  const data = toolsData.value
  const loading = toolsLoading.value
  const error = toolsError.value
  const inventory = data?.tool_inventory.tools ?? []
  const usage = data?.tool_usage ?? null
  const usageCoverageGap = usage ? coverageGapDisplay(usage) : null

  useEffect(() => {
    if (!toolsData.value && !toolsLoading.value) {
      void loadTools()
    }
  }, [])

  return html`
    <div class="v2-lab-surface flex flex-col gap-4">
      <div class="flex gap-2 mb-4">
        <${ActionButton} variant=${activeView.value === 'inventory' ? 'primary' : 'ghost'} size="md" class="v2-lab-action"
          onClick=${() => { activeView.value = 'inventory' }}>인벤토리<//>
        <${ActionButton} variant=${activeView.value === 'executor' ? 'primary' : 'ghost'} size="md" class="v2-lab-action"
          onClick=${() => { activeView.value = 'executor' }}>도구 실행기<//>
      </div>
      ${activeView.value === 'executor' ? html`<${ToolExecutor} />` : html`<div>
      <${ConfigResolutionPanel}
        resolution=${data?.config_resolution}
        runtimeResolution=${data?.runtime_resolution}
      />

      <${PromptRegistryPanel} />

      <${SectionCard} label="예약 자동화 FSM" class="section v2-lab-panel mb-4">
        <${ScheduledAutomationPanel} automation=${data?.scheduled_automation ?? null} onResolved=${loadTools} />
      <//>

      <${SectionCard} label="Keeper Waiting Inventory" class="section v2-lab-panel mb-4">
        <${KeeperWaitingInventoryPanel} inventory=${data?.keeper_waiting_inventory ?? null} />
      <//>

      <${SectionCard} label="시스템 도구 목록" class="section v2-lab-panel mb-4">
        <${FullInventoryView}
          inventory=${inventory}
          loading=${loading}
          error=${error}
        />
      <//>

      <${SectionCard} label="도구 사용 현황" class="section v2-lab-panel mb-4">
        ${usage
          ? html`
              <div class="text-xs text-[var(--color-fg-muted)] mb-2">
                등록됨 ${usage.registered_count} (모든 MCP 서버 합산) · 사용된 ${usage.distinct_tools_called} · 미사용 ${usage.never_called_count}
              </div>
              <div class="text-3xs text-[var(--color-fg-muted)] mb-2">
                <span class="font-mono">${usage.source ?? '(unknown source)'}</span>
                <span class="mx-1">·</span>
                <span class="font-mono ${sourceHealthClass(usage.health)}">${usage.health ?? 'unknown'}</span>
                <span class="mx-1">·</span>
                <span>${usage.stale_reason ?? sourceFreshnessLabel(usage.latest_age_s)}</span>
                <span class="mx-1">·</span>
                <span>${(usage.entry_count ?? 0).toLocaleString()} durable rows</span>
              </div>
              ${usageCoverageGap ? html`
                <div class="mb-2 grid gap-0.5 text-3xs text-[var(--color-status-warn)]">
                  <span>${usageCoverageGap.summary}</span>
                  ${usageCoverageGap.details.map(detail => html`<span class="font-mono break-all">${detail}</span>`)}
                </div>
              ` : null}
            `
          : null}
        <${ToolMetrics} />
      <//>
      ${data?.generated_at
        ? html`<div class="flex flex-wrap gap-x-3 gap-y-2 mt-3 text-[var(--color-fg-muted)] text-xs">
            <span>생성 시각: ${data.generated_at}</span>
            <span>metrics 기준: 최근 1시간</span>
          </div>`
        : null}

    </div>`}
    </div>
  `
}
