import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { RuntimeEnvironmentEditor } from './runtime-environment-editor'
import { keepers } from '../store'
import type { Keeper } from '../types/core'

// Regression for the live ~/.masc/config/runtime.toml shape: keeper names
// under [runtime.assignments] are quoted TOML keys. The parser fix lives in
// runtime-toml-config.test.ts; this covers the component actually renders
// the resulting assignments as pinned (not silently defaulted) and grouped.
const sourceTextWithQuotedAssignments = `[runtime]
default = "ollama_cloud.minimax-m3"

[providers.ollama_cloud]
display-name = "Ollama Cloud"
protocol = "openai-compatible-http"
endpoint = "https://ollama.example/v1"

[models.minimax-m3]
api-name = "minimax-m3"
max-context = 128000
tools-support = true
streaming = true

[models.deepseek-v4-flash]
api-name = "deepseek-v4-flash"
max-context = 128000
tools-support = true
streaming = true

[ollama_cloud.minimax-m3]

[ollama_cloud.deepseek-v4-flash]

[runtime.assignments]
"nick0cave" = "ollama_cloud.deepseek-v4-flash"
`

const sourceTextWithDefaultPinnedAssignment = sourceTextWithQuotedAssignments.replace(
  '"nick0cave" = "ollama_cloud.deepseek-v4-flash"',
  '"nick0cave" = "ollama_cloud.minimax-m3"',
)

function mountEditor(
  container: HTMLElement,
  options: {
    sourceText?: string
    onAssignmentChange?: (keeperName: string, runtimeId: string | null) => void
  } = {},
) {
  render(
    html`<${RuntimeEnvironmentEditor}
      sourceText=${options.sourceText ?? sourceTextWithQuotedAssignments}
      section="assignments"
      onRoutingChange=${() => {}}
      onAssignmentChange=${options.onAssignmentChange ?? (() => {})}
      onBindingFieldChange=${() => {}}
    />`,
    container,
  )
}

describe('RuntimeEnvironmentEditor assignments section', () => {
  afterEach(() => {
    keepers.value = []
  })

  it('groups a keeper with an explicit quoted-key assignment as pinned, not default 폴백', () => {
    const fixtureKeepers: Keeper[] = [
      { name: 'nick0cave', status: 'idle' },
      { name: 'issue_king', status: 'idle' },
    ]
    keepers.value = fixtureKeepers

    const container = document.createElement('div')
    mountEditor(container)

    const summary = container.querySelector('[data-testid="runtime-assignments-summary"]')
    expect(summary?.textContent).toContain('고정 1개')
    expect(summary?.textContent).toContain('default 폴백 1개')

    const pinnedGroup = container.querySelector('[data-testid="runtime-assignments-group-pinned"]')
    expect(pinnedGroup?.textContent).toContain('nick0cave')
    expect(pinnedGroup?.textContent).toContain('고정')

    const fallbackGroup = container.querySelector('[data-testid="runtime-assignments-group-fallback"]')
    expect(fallbackGroup?.textContent).toContain('issue_king')
    expect(fallbackGroup?.textContent).toContain('default 폴백')

    render(null, container)
  })

  it('keeps an explicit assignment pinned even when it matches the current default', () => {
    const fixtureKeepers: Keeper[] = [
      { name: 'nick0cave', status: 'idle' },
      { name: 'issue_king', status: 'idle' },
    ]
    keepers.value = fixtureKeepers

    const container = document.createElement('div')
    mountEditor(container, { sourceText: sourceTextWithDefaultPinnedAssignment })

    const summary = container.querySelector('[data-testid="runtime-assignments-summary"]')
    expect(summary?.textContent).toContain('고정 1개')
    expect(summary?.textContent).toContain('default 폴백 1개')

    const pinnedGroup = container.querySelector('[data-testid="runtime-assignments-group-pinned"]')
    expect(pinnedGroup?.textContent).toContain('nick0cave')
    expect(pinnedGroup?.textContent).toContain('고정')
    expect(pinnedGroup?.textContent).toContain('default와 같음')

    const fallbackGroup = container.querySelector('[data-testid="runtime-assignments-group-fallback"]')
    expect(fallbackGroup?.textContent).not.toContain('nick0cave')

    render(null, container)
  })

  it('uses explicit controls for pinning and clearing runtime assignments', () => {
    keepers.value = [
      { name: 'nick0cave', status: 'idle' },
      { name: 'issue_king', status: 'idle' },
    ]
    const onAssignmentChange = vi.fn()

    const container = document.createElement('div')
    mountEditor(container, { onAssignmentChange })

    fireEvent.click(
      container.querySelector(
        '[data-testid="runtime-assignment-issue_king-pin-current"]',
      ) as HTMLButtonElement,
    )
    expect(onAssignmentChange).toHaveBeenLastCalledWith(
      'issue_king',
      'ollama_cloud.minimax-m3',
    )

    fireEvent.change(
      container.querySelector('[aria-label="issue_king 런타임 배정"]') as HTMLSelectElement,
      { target: { value: 'ollama_cloud.deepseek-v4-flash' } },
    )
    expect(onAssignmentChange).toHaveBeenLastCalledWith(
      'issue_king',
      'ollama_cloud.deepseek-v4-flash',
    )

    fireEvent.click(
      container.querySelector(
        '[data-testid="runtime-assignment-nick0cave-clear"]',
      ) as HTMLButtonElement,
    )
    expect(onAssignmentChange).toHaveBeenLastCalledWith('nick0cave', null)

    render(null, container)
  })
})

const sourceWithCapabilities = `[runtime]
default = "ollama_cloud.minimax-m3"
librarian = "ollama_cloud.flash-nojson"
structured_judge = "ollama_cloud.flash-nojson"

[providers.ollama_cloud]
display-name = "Ollama Cloud"
protocol = "openai-compatible-http"
endpoint = "https://ollama.example/v1"

[models.minimax-m3]
api-name = "minimax-m3"
max-context = 524288
tools-support = true
thinking-support = true
streaming = true

[models.minimax-m3.capabilities]
supports-tool-choice = true
supports-response-format-json = true
supports-structured-output = true
supports-multimodal-inputs = true
thinking-control-format = "reasoning-effort"

[models.flash-nojson]
api-name = "deepseek-v4-flash"
max-context = 1048576
tools-support = true
thinking-support = true
streaming = true

[models.flash-nojson.capabilities]
supports-response-format-json = false
supports-structured-output = false
thinking-control-format = "reasoning-effort"

[ollama_cloud.minimax-m3]
price-input = 0.14
price-output = 0.28

[ollama_cloud.flash-nojson]
`

function mountSection(container: HTMLElement, section: 'models' | 'routing' | 'bindings') {
  render(
    html`<${RuntimeEnvironmentEditor}
      sourceText=${sourceWithCapabilities}
      section=${section}
      onRoutingChange=${() => {}}
      onAssignmentChange=${() => {}}
      onBindingFieldChange=${() => {}}
    />`,
    container,
  )
}

describe('RuntimeEnvironmentEditor capability projection', () => {
  it('renders model capability chips from the [models.<id>.capabilities] section', () => {
    const container = document.createElement('div')
    mountSection(container, 'models')

    const text = container.querySelector('[data-testid="runtime-section-models"]')?.textContent ?? ''
    expect(text).toContain('tool-choice')
    expect(text).toContain('json')
    expect(text).toContain('structured')
    expect(text).toContain('multimodal')
    expect(text).toContain('effort: reasoning-effort')
    // the honest "no source" stub is gone now that a live source exists
    expect(text).not.toContain('effort: 미수집')

    render(null, container)
  })

  it('warns when a JSON-required lane targets a model without response-format-json', () => {
    const container = document.createElement('div')
    mountSection(container, 'routing')

    const warnings = Array.from(container.querySelectorAll('.rt-warn')).map(node => node.textContent ?? '')
    expect(warnings.some(w => w.includes('JSON 모드 필요') && w.includes('deepseek-v4-flash 미지원'))).toBe(true)

    render(null, container)
  })

  it('warns on the structured_judge lane for structured output, not JSON mode', () => {
    // Server contract: [runtime].structured_judge must declare
    // supports-structured-output, not just JSON mode (lib/runtime/runtime.ml:142-151).
    const container = document.createElement('div')
    mountSection(container, 'routing')

    const warnings = Array.from(container.querySelectorAll('.rt-warn')).map(node => node.textContent ?? '')
    expect(warnings.some(w => w.includes('structured output 필요') && w.includes('deepseek-v4-flash 미지원'))).toBe(true)
    // and it does not mislabel the structured requirement as a JSON-mode one
    expect(warnings.every(w => !(w.includes('structured output 필요') && w.includes('JSON 모드')))).toBe(true)

    render(null, container)
  })

  it('shows per-M binding price and the model effort mode in the binding sub-line', () => {
    const container = document.createElement('div')
    mountSection(container, 'bindings')

    const text = container.querySelector('[data-testid="runtime-section-bindings"]')?.textContent ?? ''
    expect(text).toContain('$0.14/$0.28 per M')
    expect(text).toContain('effort reasoning-effort')
    expect(text).not.toContain('가격/effort 미수집')

    render(null, container)
  })
})
