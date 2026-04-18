import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { SurfaceCard } from '../common/card'
import { ActionButton } from '../common/button'
import { SchemaForm } from './schema-form'
import { ToolPicker } from './tool-picker'
import { ToolResultDisplay } from './tool-result-display'
import {
  selectedTool, formValues, validationErrors, executing, lastResult,
  schemasLoading, schemasError, loadToolSchemas, updateFormValues, executeTool, clearSelection,
} from './tool-executor-state'

function ConfirmDialog({ toolName, onConfirm, onCancel }: { toolName: string; onConfirm: () => void; onCancel: () => void }) {
  return html`
    <div class="rounded border border-[rgba(251,113,133,0.4)] bg-[var(--bad-10)] p-3">
      <p class="text-xs text-[var(--bad-light)] mb-2"><strong>${toolName}</strong> 은 파괴적(destructive) 도구입니다. 실행하시겠습니까?</p>
      <div class="flex gap-2">
        <${ActionButton} variant="danger" size="sm" onClick=${onConfirm}>실행<//>
        <${ActionButton} variant="ghost" size="sm" onClick=${onCancel}>취소<//>
      </div>
    </div>
  `
}

function ToolDetail() {
  const showConfirm = useSignal(false)
  const tool = selectedTool.value
  if (!tool) return html`<div class="flex items-center justify-center h-full text-[var(--text-muted)] text-sm">좌측에서 도구를 선택하세요.</div>`

  const isDestructive = tool.annotations?.destructiveHint === true
  const missing = validationErrors.value
  const handleExecute = () => { if (isDestructive) { showConfirm.value = true } else { void executeTool() } }
  const handleConfirmedExecute = () => { showConfirm.value = false; void executeTool() }

  return html`
    <div class="flex flex-col gap-3 h-full overflow-y-auto">
      <div>
        <h3 class="text-base text-[var(--text-strong)] font-mono font-medium">${tool.name}</h3>
        <p class="text-xs text-[var(--text-muted)] mt-1">${tool.description}</p>
        ${tool.annotations?.readOnlyHint === true ? html`<span class="text-3xs text-[var(--ok)] mt-1">읽기 전용</span>` : null}
        ${isDestructive ? html`<span class="text-3xs text-[var(--bad)] mt-1 ml-2">파괴적</span>` : null}
      </div>
      <div class="border-t border-[var(--card-border)] pt-3">
        <${SchemaForm} schema=${tool.inputSchema} values=${formValues.value} onChange=${updateFormValues} />
      </div>
      ${missing.length > 0 ? html`<p class="text-2xs text-[var(--bad)]">필수 필드 누락: ${missing.join(', ')}</p>` : null}
      ${showConfirm.value
        ? html`<${ConfirmDialog} toolName=${tool.name} onConfirm=${handleConfirmedExecute} onCancel=${() => { showConfirm.value = false }} />`
        : html`
          <div class="flex gap-2">
            <${ActionButton} variant=${isDestructive ? 'danger' : 'primary'} size="md" disabled=${executing.value} onClick=${handleExecute}>
              ${executing.value ? '실행 중...' : '실행'}<//>
            <${ActionButton} variant="ghost" size="md" onClick=${() => { clearSelection(); showConfirm.value = false }}>초기화<//>
          </div>`}
      ${lastResult.value ? html`<${ToolResultDisplay} key=${lastResult.value.timestamp} ...${lastResult.value} />` : null}
    </div>
  `
}

export function ToolExecutor() {
  useEffect(() => { void loadToolSchemas() }, [])
  if (schemasLoading.value && !selectedTool.value) {
    return html`<${SurfaceCard}><p class="text-xs text-[var(--text-muted)] py-8 text-center">도구 스키마 로딩 중...</p><//>`
  }
  if (schemasError.value) {
    return html`<${SurfaceCard}><div class="py-4 text-center">
      <p class="text-xs text-[var(--bad)] mb-2">${schemasError.value}</p>
      <${ActionButton} variant="ghost" size="sm" onClick=${() => void loadToolSchemas(true)}>재시도<//>
    </div><//>`
  }
  return html`
    <${SurfaceCard} class="h-[calc(100vh-240px)] min-h-100">
      <div class="flex gap-4 h-full">
        <div class="w-70 flex-shrink-0 border-r border-[var(--card-border)] pr-4"><${ToolPicker} /></div>
        <div class="flex-1 min-w-0"><${ToolDetail} /></div>
      </div>
    <//>
  `
}
