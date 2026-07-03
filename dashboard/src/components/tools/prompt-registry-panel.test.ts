import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

void vi

const mocks = vi.hoisted(() => ({
  clearPromptOverride: vi.fn(async () => ({ ok: true, message: 'override cleared' })),
  fetchDashboardPrompts: vi.fn(),
  savePromptOverride: vi.fn(async () => ({ ok: true, message: 'override set' })),
}))

vi.mock('../../api', () => ({
  clearPromptOverride: mocks.clearPromptOverride,
  fetchDashboardPrompts: mocks.fetchDashboardPrompts,
  savePromptOverride: mocks.savePromptOverride,
}))

import type { DashboardPromptItem } from '../../api'
import { PromptRegistryPanel, promptSourceCounts } from './prompt-registry-panel'

function makePrompt(overrides: Partial<DashboardPromptItem>): DashboardPromptItem {
  return {
    key: 'keeper.system',
    category: 'keeper',
    description: 'Keeper system prompt',
    current: '',
    default: null,
    effective: '',
    file_value: null,
    override_value: null,
    file_path: null,
    file_exists: true,
    source: 'file',
    has_override: false,
    char_count: 0,
    required_file: true,
    template_variables: [],
    ...overrides,
  }
}

const HELPER_FIXTURES: DashboardPromptItem[] = [
  makePrompt({ key: 'keeper.system', category: 'keeper', description: 'k1', source: 'file' }),
  makePrompt({ key: 'keeper.turn', category: 'keeper', description: 'k2', source: 'override' }),
  makePrompt({ key: 'planner.root', category: 'planner', description: 'p1', source: 'default' }),
  makePrompt({ key: 'planner.step', category: 'planner', description: 'p2', source: 'missing' }),
  makePrompt({
    key: 'supervisor.brief',
    category: 'supervisor',
    description: 'supervisor briefing template',
    source: 'file',
  }),
]

function defaultPromptItems(): DashboardPromptItem[] {
  return [
    makePrompt({
      key: 'keeper.world',
      category: 'keeper',
      description: 'world block',
      current: 'override world',
      default: 'file world',
      effective: 'override world',
      file_value: 'file world',
      override_value: 'override world',
      file_path: 'fixture/config/prompts/keeper.world.md',
      source: 'override',
      has_override: true,
      char_count: 14,
      template_variables: ['keeper'],
    }),
    makePrompt({
      key: 'governance.dry_run',
      category: 'governance',
      description: 'dry run block',
      current: 'dry run prompt',
      default: 'dry run prompt',
      effective: 'dry run prompt',
      file_value: 'dry run prompt',
      override_value: null,
      file_path: 'fixture/config/prompts/governance.dry_run.md',
      source: 'file',
      has_override: false,
      char_count: 14,
      template_variables: [],
    }),
  ]
}

describe('promptSourceCounts', () => {
  it('counts each source and total', () => {
    expect(promptSourceCounts(HELPER_FIXTURES)).toEqual({
      all: 5,
      file: 2,
      override: 1,
      default: 1,
      missing: 1,
    })
  })

  it('returns zeros on empty input', () => {
    expect(promptSourceCounts([])).toEqual({
      all: 0,
      file: 0,
      override: 0,
      default: 0,
      missing: 0,
    })
  })
})

async function flush() {
  await new Promise(resolve => setTimeout(resolve, 0))
}

describe('PromptRegistryPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    mocks.clearPromptOverride.mockClear()
    mocks.fetchDashboardPrompts.mockReset()
    mocks.fetchDashboardPrompts.mockResolvedValue({ prompts: defaultPromptItems() })
    mocks.savePromptOverride.mockClear()
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
    expect(container.querySelector('.v2-lab-panel')).not.toBeNull()
    expect(container.querySelector('.v2-lab-row')).not.toBeNull()
    expect(container.textContent).toContain('프롬프트 레지스트리')
    expect(container.textContent).toContain('keeper.world')
    expect(container.textContent).toContain('fixture/config/prompts/keeper.world.md')
    expect(container.querySelector('[data-prompt-preset-switcher]')).not.toBeNull()
    expect(container.querySelector('[data-prompt-destinations]')?.textContent).toContain('System rules')
    expect(container.querySelector('[data-prompt-destinations]')?.textContent).toContain('system')
    expect(container.textContent).toContain('{{keeper}}')
    await waitFor(() => {
      expect(container.textContent).toContain('file world')
    })
    expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toBe('override world')

    const allPreset = container.querySelector('[data-prompt-preset-switcher] button') as HTMLButtonElement
    allPreset?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()

    const governanceButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('governance.dry_run'),
    )
    governanceButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()

    expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toBe('dry run prompt')
  })

  it('rebinds the clean editor draft to the first visible prompt when filters hide the selection', async () => {
    render(html`<${PromptRegistryPanel} />`, container)
    await flush()
    await flush()

    const textarea = () => container.querySelector('textarea') as HTMLTextAreaElement
    expect(textarea().value).toBe('override world')

    const fileChip = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('파일'),
    ) as HTMLButtonElement | undefined
    expect(fileChip).toBeTruthy()
    await fireEvent.click(fileChip!)

    await waitFor(() => {
      expect(textarea().value).toBe('dry run prompt')
    })
    expect(container.textContent).toContain('governance.dry_run')
    expect(container.textContent).toContain('fixture/config/prompts/governance.dry_run.md')
  })

  it('keeps dirty draft text across filters and confirms before discarding on row selection', async () => {
    render(html`<${PromptRegistryPanel} />`, container)
    await flush()
    await flush()

    const textarea = () => container.querySelector('textarea') as HTMLTextAreaElement
    const searchInput = () =>
      container.querySelector('input[aria-label="프롬프트 검색"]') as HTMLInputElement
    const governanceButton = () =>
      Array.from(container.querySelectorAll('button')).find(button =>
        button.textContent?.includes('governance.dry_run'),
      ) as HTMLButtonElement | undefined

    await fireEvent.input(textarea(), { target: { value: 'edited unsaved draft' } })
    await fireEvent.input(searchInput(), { target: { value: 'governance' } })
    await flush()

    expect(textarea().value).toBe('edited unsaved draft')

    const originalConfirm = window.confirm
    const confirmSpy = vi.fn(() => false)
    window.confirm = confirmSpy
    try {
      await fireEvent.click(governanceButton()!)
      await flush()

      expect(confirmSpy).toHaveBeenCalledTimes(1)
      expect(textarea().value).toBe('edited unsaved draft')

      confirmSpy.mockReturnValue(true)
      await fireEvent.click(governanceButton()!)
      await flush()

      expect(textarea().value).toBe('dry run prompt')
    } finally {
      window.confirm = originalConfirm
      await fireEvent.input(searchInput(), { target: { value: '' } })
    }
  })

  it('rebinds the draft when reload removes the selected prompt before saving', async () => {
    const remainingPrompt = defaultPromptItems()[1]
    mocks.fetchDashboardPrompts
      .mockResolvedValueOnce({ prompts: defaultPromptItems() })
      .mockResolvedValueOnce({ prompts: [remainingPrompt] })

    render(html`<${PromptRegistryPanel} />`, container)
    await flush()
    await flush()

    const textarea = () => container.querySelector('textarea') as HTMLTextAreaElement
    await fireEvent.input(textarea(), { target: { value: 'stale keeper draft' } })

    const refreshButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('새로고침'),
    ) as HTMLButtonElement
    await fireEvent.click(refreshButton)

    await waitFor(() => {
      expect(textarea().value).toBe('dry run prompt')
    })

    const applyButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('오버라이드 적용'),
    ) as HTMLButtonElement
    await fireEvent.click(applyButton)

    await waitFor(() => {
      expect(mocks.savePromptOverride).toHaveBeenCalledWith('governance.dry_run', 'dry run prompt')
    })
  })

  it('toggles from the registry editor to the read-only prompt library', async () => {
    render(html`<${PromptRegistryPanel} />`, container)
    await flush()
    await flush()

    // the registry editor is the landing view
    expect(container.querySelector('textarea')).not.toBeNull()
    expect(container.querySelector('[data-testid="prompt-book-panel"]')).toBeNull()

    const libraryTab = Array.from(container.querySelectorAll('[data-prompt-view-switcher] button')).find(button =>
      button.textContent?.includes('라이브러리'),
    ) as HTMLButtonElement
    expect(libraryTab).toBeTruthy()
    await fireEvent.click(libraryTab)

    // the library replaces the editor; it reuses the already-fetched prompts (no refetch)
    expect(container.querySelector('[data-testid="prompt-book-panel"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="prompt-book-catalog"]')).not.toBeNull()
    expect(container.querySelector('textarea')).toBeNull()
    expect(mocks.fetchDashboardPrompts).toHaveBeenCalledTimes(1)
  })
})
