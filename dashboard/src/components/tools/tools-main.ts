// Tools main component — orchestrates inventory and executor views

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { Card } from '../common/card'
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

type ToolsView = 'inventory' | 'executor'
const activeView = signal<ToolsView>('inventory')

export function Tools() {
  const data = toolsData.value
  const loading = toolsLoading.value
  const error = toolsError.value
  const inventory = data?.tool_inventory.tools ?? []
  const usage = data?.tool_usage ?? null

  useEffect(() => {
    if (!toolsData.value && !toolsLoading.value) {
      void loadTools()
    }
  }, [])

  return html`
    <div>
      <div class="flex gap-2 mb-4">
        <${ActionButton} variant=${activeView.value === 'inventory' ? 'primary' : 'ghost'} size="md"
          onClick=${() => { activeView.value = 'inventory' }}>인벤토리<//>
        <${ActionButton} variant=${activeView.value === 'executor' ? 'primary' : 'ghost'} size="md"
          onClick=${() => { activeView.value = 'executor' }}>도구 실행기<//>
      </div>
      ${activeView.value === 'executor' ? html`<${ToolExecutor} />` : html`<div>
      <${ConfigResolutionPanel}
        resolution=${data?.config_resolution}
        runtimeResolution=${data?.runtime_resolution}
      />

      <${Card} title="시스템 도구 목록" class="section mb-4">
        <${FullInventoryView}
          inventory=${inventory}
          loading=${loading}
          error=${error}
        />
      <//>

      <${Card} title="도구 사용 현황" class="section mb-4">
        ${usage
          ? html`
              <div class="text-[12px] text-[var(--text-muted)] mb-2">
                등록됨 ${usage.registered_count} (모든 MCP 서버 합산) · 사용된 ${usage.distinct_tools_called} · 미사용 ${usage.never_called_count}
              </div>
            `
          : null}
        <${ToolMetrics} />
      <//>
      ${data?.generated_at
        ? html`<div class="flex flex-wrap gap-x-3 gap-y-2 mt-3 text-[var(--text-muted)] text-[12px]">
            <span>생성 시각: ${data.generated_at}</span>
            <span>metrics 기준: 최근 1시간</span>
          </div>`
        : null}

      <${PromptRegistryPanel} />
    </div>`}
    </div>
  `
}
