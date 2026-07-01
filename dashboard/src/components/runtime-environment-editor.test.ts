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
