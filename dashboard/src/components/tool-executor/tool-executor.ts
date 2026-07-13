import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { SurfaceCard } from '../common/card'
import { ActionButton } from '../common/button'
import { SchemaForm } from './schema-form'
import { ToolPicker } from './tool-picker'
import { ToolResultDisplay } from './tool-result-display'
import {
  selectedTool, formValues, validationErrors, executing, lastResult,
  schemasLoading, schemasError, loadToolSchemas, updateFormValues, executeTool, clearSelection, selectedToolAccess,
} from './tool-executor-state'

function ToolDetail() {
  const tool = selectedTool.value
  if (!tool) return html`<div class="flex items-center justify-center h-full text-[var(--color-fg-muted)] text-sm">좌측에서 도구를 선택하세요.</div>`

  const missing = validationErrors.value
  const toolAccess = selectedToolAccess.value
  const handleExecute = () => { void executeTool() }

  return html`
    <div class="flex flex-col gap-3 h-full overflow-y-auto">
      <div>
        <h3 class="text-base text-[var(--color-fg-secondary)] font-mono font-medium">${tool.name}</h3>
        <p class="text-xs text-[var(--color-fg-muted)] mt-1">${tool.description}</p>
        ${tool.annotations?.readOnlyHint === true ? html`<span class="text-3xs text-[var(--color-status-ok)] mt-1">읽기 전용</span>` : null}
      </div>
      <div class="border-t border-[var(--color-border-default)] pt-3">
        <${SchemaForm} schema=${tool.inputSchema} values=${formValues.value} onChange=${updateFormValues} />
      </div>
      ${toolAccess.allowed ? null : html`
        <p class="text-2xs text-[var(--color-status-warn)]">
          실행 차단: ${toolAccess.reason ?? `${toolAccess.required_role} 권한이 필요합니다.`}
        </p>
      `}
      ${missing.length > 0 ? html`<p class="text-2xs text-[var(--color-status-err)]">필수 필드 누락: ${missing.join(', ')}</p>` : null}
      <div class="flex gap-2">
        <${ActionButton} variant="primary" size="md" disabled=${executing.value || !toolAccess.allowed} onClick=${handleExecute} title="실행: 정확한 입력을 Gate로 전달합니다">
          ${executing.value ? '실행 중...' : '실행하기'}<//>
        <${ActionButton} variant="ghost" size="md" onClick=${clearSelection} title="초기화: 선택과 입력값을 비웁니다">초기화하기<//>
      </div>
      ${lastResult.value ? html`<${ToolResultDisplay} key=${lastResult.value.timestamp} ...${lastResult.value} />` : null}
    </div>
  `
}

export function ToolExecutor() {
  useEffect(() => { void loadToolSchemas() }, [])
  if (schemasLoading.value && !selectedTool.value) {
    return html`<${SurfaceCard}><p class="text-xs text-[var(--color-fg-muted)] py-8 text-center" role="status">도구 스키마 로딩 중...</p><//>`
  }
  if (schemasError.value) {
    return html`<${SurfaceCard}><div class="py-4 text-center">
      <p class="text-xs text-[var(--color-status-err)] mb-2">${schemasError.value}</p>
      <${ActionButton} variant="ghost" size="sm" onClick=${() => void loadToolSchemas(true)}>재시도<//>
    </div><//>`
  }
  return html`
    <${SurfaceCard} class="h-[calc(100vh-240px)] min-h-100">
      <div class="flex gap-4 h-full">
        <div class="w-70 flex-shrink-0 border-r border-[var(--color-border-default)] pr-4"><${ToolPicker} /></div>
        <div class="flex-1 min-w-0"><${ToolDetail} /></div>
      </div>
    <//>
  `
}
