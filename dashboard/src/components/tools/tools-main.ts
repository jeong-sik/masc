// Tools main component — orchestrates summary/full inventory views

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { Card } from '../common/card'
import { ToolMetrics } from '../tool-metrics'
import {
  toolsData,
  toolsLoading,
  toolsError,
  showFullInventory,
  loadTools,
} from './tool-state'
import { ToolSummaryView } from './tool-summary-view'
import { FullInventoryView } from './tool-full-inventory'
import { PromptRegistryPanel } from './prompt-registry-panel'

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
      <${Card} title="시스템 도구 목록" class="section mb-4">
        <div class="mb-4">
          <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">
            ${showFullInventory.value
              ? 'hidden/deprecated 포함 전체 도구 surface를 봅니다.'
              : '필수 도구와 사용 현황 요약입니다.'}
          </p>
          <button type="button"
            class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)] mt-2"
            onClick=${() => { showFullInventory.value = !showFullInventory.value }}
          >
            ${showFullInventory.value ? '요약 보기' : '전체 인벤토리 보기'}
          </button>
        </div>

        ${showFullInventory.value
          ? html`<${FullInventoryView}
              inventory=${inventory}
              loading=${loading}
              error=${error}
            />`
          : html`<${ToolSummaryView} inventory=${inventory} />`
        }
      <//>

      <${Card} title="도구 사용 현황" class="section mb-4">
        ${usage
          ? html`
              <div class="text-[12px] text-[var(--text-muted)] mb-2">
                등록됨 ${usage.registered_count} · 사용된 ${usage.distinct_tools_called} · 미사용 ${usage.never_called_count}
              </div>
            `
          : null}
        <${ToolMetrics} />
      <//>
      <${PromptRegistryPanel} />
      ${data?.generated_at
        ? html`<div class="flex flex-wrap gap-x-3 gap-y-2 mt-3 text-[var(--text-muted)] text-[12px]">
            <span>생성 시각: ${data.generated_at}</span>
            <span>metrics 기준: 최근 1시간</span>
          </div>`
        : null}
    </div>
  `
}
