import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

void vi

const mocks = vi.hoisted(() => ({
  fetchDashboardPrompts: vi.fn(async () => ({
    prompts: [
      {
        key: 'keeper.world',
        category: 'keeper',
        description: 'world block',
        current: 'override world',
        default: 'file world',
        effective: 'override world',
        file_value: 'file world',
        override_value: 'override world',
        file_path: '/tmp/config/prompts/keeper.world.md',
        file_exists: true,
        source: 'override' as const,
        has_override: true,
        char_count: 14,
        required_file: true,
        template_variables: [],
      },
      {
        key: 'governance.dry_run',
        category: 'governance',
        description: 'dry run block',
        current: 'dry run prompt',
        default: 'dry run prompt',
        effective: 'dry run prompt',
        file_value: 'dry run prompt',
        override_value: null,
        file_path: '/tmp/config/prompts/governance.dry_run.md',
        file_exists: true,
        source: 'file' as const,
        has_override: false,
        char_count: 14,
        required_file: true,
        template_variables: [],
      },
    ],
  })),
}))

vi.mock('../../api', () => ({
  clearPromptOverride: vi.fn(async () => ({ ok: true, message: 'override cleared' })),
  fetchDashboardPrompts: mocks.fetchDashboardPrompts,
  savePromptOverride: vi.fn(async () => ({ ok: true, message: 'override set' })),
}))

import { PromptRegistryPanel } from './prompt-registry-panel'

async function flush() {
  await new Promise(resolve => setTimeout(resolve, 0))
}

describe('PromptRegistryPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    mocks.fetchDashboardPrompts.mockClear()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders prompt metadata and switches the editor draft when selection changes', async () => {
    render(html`<${PromptRegistryPanel} />`, container)
    await flush()
    await flush()

    expect(mocks.fetchDashboardPrompts).toHaveBeenCalledTimes(1)
    expect(container.textContent).toContain('프롬프트 레지스트리')
    expect(container.textContent).toContain('keeper.world')
    expect(container.textContent).toContain('/tmp/config/prompts/keeper.world.md')
    expect(container.textContent).toContain('file world')
    expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toBe('override world')

    const governanceButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('governance.dry_run'),
    )
    governanceButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()

    expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toBe('dry run prompt')
  })
})
