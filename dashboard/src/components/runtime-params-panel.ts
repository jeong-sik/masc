// MASC Dashboard — Runtime parameters
//
// The Runtime_params registry: every knob this build registered, what the
// workspace runs on now, and what it would be with nobody overriding it.
//
// Not runtime.toml. That file says which runtimes and lanes exist; this says
// how the ones that exist behave. Two different questions, and the reason they
// are two screens is that one value must not be claimed by two files -- an
// override lives in .masc/runtime_params.json and nowhere else.
//
// Data: GET /api/v1/runtime/params. Actions: set / clear, both server-validated
// against the bounds the parameter registered.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  fetchRuntimeParams,
  setRuntimeParam,
  clearRuntimeParam,
  type RuntimeParam,
} from '../api/dashboard-runtime'
import { SectionCard } from './common/card'
import { ErrorState, LoadingState, EmptyState } from './common/feedback-state'
import { showToast } from './common/toast'

function formatValue(value: unknown): string {
  if (value === null || value === undefined) return '—'
  if (typeof value === 'string') return value
  return JSON.stringify(value)
}

/**
 * Parse what an operator typed back into the type the parameter registered.
 *
 * Refuses rather than guesses. Sending "3" where an int was registered makes
 * the server reject the write, and a value that silently became a string is
 * the shape that reads as "saved" on screen while nothing changed.
 */
function parseValue(raw: string, valueType: string): { ok: true; value: unknown } | { ok: false; detail: string } {
  const text = raw.trim()
  if (text === '') return { ok: false, detail: '값을 입력하세요' }
  switch (valueType) {
    case 'int': {
      if (!/^-?\d+$/.test(text)) return { ok: false, detail: '정수여야 합니다' }
      return { ok: true, value: Number.parseInt(text, 10) }
    }
    case 'float': {
      const n = Number(text)
      if (!Number.isFinite(n)) return { ok: false, detail: '숫자여야 합니다' }
      return { ok: true, value: n }
    }
    case 'bool': {
      if (text === 'true') return { ok: true, value: true }
      if (text === 'false') return { ok: true, value: false }
      return { ok: false, detail: 'true 또는 false' }
    }
    case 'string':
      return { ok: true, value: text }
    default:
      // A type this build does not know how to type is not one to send
      // anyway: the server would validate it against a shape the screen
      // cannot show.
      return { ok: false, detail: `이 화면이 모르는 타입입니다: ${valueType}` }
  }
}

function boundsText(param: RuntimeParam): string | null {
  const meta = param.meta
  if (!meta) return null
  const min = meta.min_value
  const max = meta.max_value
  if (min === undefined && max === undefined) return null
  if (min !== undefined && max !== undefined) return `${min} ~ ${max}`
  return min !== undefined ? `≥ ${min}` : `≤ ${max}`
}

function ParamRow({
  param,
  acting,
  onSet,
  onClear,
}: {
  param: RuntimeParam
  acting: string | null
  onSet: (key: string, raw: string) => void
  onClear: (key: string) => void
}) {
  const draft = useSignal('')
  const busy = acting === param.key
  const bounds = boundsText(param)
  const valueType = param.meta?.value_type ?? 'unknown'
  return html`
    <li class="grid gap-1 border-b border-[var(--color-border-divider)] py-3 last:border-b-0"
        data-testid="runtime-param-row">
      <div class="flex flex-wrap items-baseline gap-2">
        <span class="font-mono text-xs">${param.key}</span>
        ${param.has_override
          ? html`<span class="rounded px-1 text-2xs text-[var(--color-fg-warning)]"
                       data-testid="runtime-param-overridden">override</span>`
          : null}
        <span class="text-2xs text-[var(--color-fg-muted)]">${valueType}${bounds ? ` · ${bounds}` : ''}</span>
      </div>
      ${param.meta?.description
        ? html`<div class="text-2xs text-[var(--color-fg-muted)]">${param.meta.description}</div>`
        : null}
      <div class="flex flex-wrap items-center gap-2 text-xs">
        <span class="font-mono" data-testid="runtime-param-current">${formatValue(param.current)}</span>
        ${param.has_override
          ? html`<span class="text-2xs text-[var(--color-fg-muted)]">
              기본값 ${formatValue(param.default)}
            </span>`
          : null}
        <input
          class="w-28 rounded border border-[var(--color-border-divider)] bg-transparent px-2 py-1 font-mono text-xs"
          value=${draft.value}
          disabled=${busy}
          placeholder=${formatValue(param.default)}
          aria-label=${`${param.key} 새 값`}
          onInput=${(e: Event) => { draft.value = (e.target as HTMLInputElement).value }}
        />
        <button type="button" class="rounded border border-[var(--color-border-divider)] px-2 py-1 text-xs"
                disabled=${busy}
                onClick=${() => { onSet(param.key, draft.value); draft.value = '' }}>
          ${busy ? '저장 중' : '저장'}
        </button>
        ${param.has_override
          ? html`<button type="button" class="rounded border border-[var(--color-border-divider)] px-2 py-1 text-xs"
                         disabled=${busy}
                         onClick=${() => onClear(param.key)}>기본값으로</button>`
          : null}
      </div>
    </li>
  `
}

export function RuntimeParamsPanel() {
  const params = useSignal<RuntimeParam[] | null>(null)
  const error = useSignal<string | null>(null)
  const acting = useSignal<string | null>(null)

  const load = async () => {
    try {
      params.value = await fetchRuntimeParams()
      error.value = null
    } catch (err) {
      error.value = err instanceof Error ? err.message : '런타임 설정을 읽지 못했습니다'
    }
  }

  useEffect(() => { void load() }, [])

  const onSet = async (key: string, raw: string) => {
    const param = params.value?.find(p => p.key === key)
    const parsed = parseValue(raw, param?.meta?.value_type ?? 'unknown')
    if (!parsed.ok) {
      showToast(`${key}: ${parsed.detail}`, 'error')
      return
    }
    acting.value = key
    try {
      await setRuntimeParam(key, parsed.value)
      // Re-read rather than patching the row: the server is what decides what
      // the value became, and a screen that assumes otherwise shows a number
      // nobody is running on.
      await load()
      showToast(`${key} 저장됨`, 'success')
    } catch (err) {
      showToast(err instanceof Error ? err.message : `${key} 저장 실패`, 'error')
    } finally {
      acting.value = null
    }
  }

  const onClear = async (key: string) => {
    acting.value = key
    try {
      await clearRuntimeParam(key)
      await load()
      showToast(`${key} 기본값으로`, 'success')
    } catch (err) {
      showToast(err instanceof Error ? err.message : `${key} 해제 실패`, 'error')
    } finally {
      acting.value = null
    }
  }

  return html`
    <${SectionCard} title="런타임 설정" data-testid="runtime-params-panel">
      <div class="mb-2 text-2xs text-[var(--color-fg-muted)]">
        재시작 없이 적용됩니다. 기본값은 환경변수에서 오고, 바꾼 값만
        <span class="font-mono">.masc/runtime_params.json</span> 에 남습니다.
      </div>
      ${error.value !== null
        ? html`<${ErrorState} message=${error.value} />`
        : params.value === null
        ? html`<${LoadingState} />`
        : params.value.length === 0
        ? html`<${EmptyState} message="등록된 설정 없음" />`
        : html`
            <ul class="list-none p-0">
              ${params.value.map(param => html`
                <${ParamRow}
                  key=${param.key}
                  param=${param}
                  acting=${acting.value}
                  onSet=${onSet}
                  onClear=${onClear}
                />
              `)}
            </ul>
          `}
    <//>
  `
}
