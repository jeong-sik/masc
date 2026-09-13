import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

void vi

const mocks = vi.hoisted(() => ({
  clearPromptOverride: vi.fn(async () => ({ ok: true, message: 'override cleared' })),
  fetchDashboardPrompts: vi.fn(),
  savePromptOverride: vi.fn(async () => ({ ok: true, message: 'override set' } as Awaited<ReturnType<typeof import('../../api').savePromptOverride>>)),
}))

vi.mock('../../api', () => ({
  clearPromptOverride: mocks.clearPromptOverride,
  fetchDashboardPrompts: mocks.fetchDashboardPrompts,
  savePromptOverride: mocks.savePromptOverride,
}))

import type { DashboardPromptItem } from '../../api'
import type { KeeperPromptAssemblyReport } from '../keeper-prompt-assembly-panel'
import {
  PromptRegistryPanel,
  filterPrompts,
  promptPresetOptions,
  promptSourceCounts,
} from './prompt-registry-panel'

const EMPTY_REPORT: KeeperPromptAssemblyReport = {
  rows: [],
  stages: [],
  warnings: [],
  activePromptRoots: [],
  stats: {
    totalRows: 0,
    overrideRows: 0,
    missingRows: 0,
    warningCount: 0,
    criticalCount: 0,
    sentPromptBytes: 0,
    sentEstimatedTokens: 0,
  },
}

function makePrompt(overrides: Partial<DashboardPromptItem>): DashboardPromptItem {
  return {
    key: 'keeper',
    category: 'keeper',
    description: 'Keeper system prompt',
    current: '',
    effective: '',
    file_value: null,
    override_value: null,
    file_path: null,
    source: 'file',
    char_count: 0,
    required_file: true,
    template_variables: [],
    ...overrides,
  }
}

const HELPER_FIXTURES: DashboardPromptItem[] = [
  makePrompt({ key: 'keeper', category: 'keeper', description: 'k1', source: 'file' }),
  makePrompt({ key: 'keeper.turn', category: 'keeper', description: 'k2', source: 'override' }),
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
      key: 'keeper',
      category: 'keeper',
      description: 'world block',
      current: 'override world',
      effective: 'override world',
      file_value: 'file world',
      override_value: 'override world',
      file_path: 'fixture/config/prompts/keeper.md',
      source: 'override',
      char_count: 14,
      template_variables: ['keeper'],
    }),
    makePrompt({
      key: 'analysis.dry_run',
      category: 'analysis',
      description: 'dry run block',
      current: 'dry run prompt',
      effective: 'dry run prompt',
      file_value: 'dry run prompt',
      override_value: null,
      file_path: 'fixture/config/prompts/analysis.dry_run.md',
      source: 'file',
      char_count: 14,
      template_variables: [],
    }),
    makePrompt({
      key: 'librarian',
      category: 'librarian',
      description: 'Memory OS librarian current-memory selection prompt',
      current: 'Keep {{current_memory}} from {{conversation_history}}',
      effective: 'Keep {{current_memory}} from {{conversation_history}}',
      file_value: 'Keep {{current_memory}} from {{conversation_history}}',
      file_path: 'fixture/config/prompts/librarian.md',
      source: 'file',
      char_count: 55,
      template_variables: [
        'current_memory',
        'conversation_history',
        'counterpart_observations',
        'keeper_instructions',
      ],
    }),
  ]
}

describe('promptSourceCounts', () => {
  it('counts each source and total', () => {
    expect(promptSourceCounts(HELPER_FIXTURES)).toEqual({
      all: 4,
      file: 2,
      override: 1,
      missing: 1,
    })
  })

  it('returns zeros on empty input', () => {
    expect(promptSourceCounts([])).toEqual({
      all: 0,
      file: 0,
      override: 0,
      missing: 0,
    })
  })
})

describe('the 수정/누락 tab', () => {
  // The tab prints a count and then a list of rows. Those were two spellings
  // of one predicate -- one over has_override, one over source -- eighty lines
  // apart in the same file, and no test compared them. A prompt whose override
  // was in force but whose has_override said otherwise would have been counted
  // by one and hidden by the other.
  it('counts exactly the rows it then shows', () => {
    const counted = promptPresetOptions(HELPER_FIXTURES, EMPTY_REPORT).find(
      preset => preset.id === 'attention',
    )?.count
    const shown = filterPrompts(HELPER_FIXTURES, 'all', '', EMPTY_REPORT, 'attention')
    expect(counted).toBe(shown.length)
  })

  it('is the prompts that are not simply the file', () => {
    const shown = filterPrompts(HELPER_FIXTURES, 'all', '', EMPTY_REPORT, 'attention')
    expect(shown.map(prompt => prompt.key)).toEqual(['keeper.turn', 'planner.step'])
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

  it('opens all preset source text without changing drafts or saving', async () => {
    const literal = '<script>do not execute</script>\n{{context}}\nlast line';
    mocks.fetchDashboardPrompts.mockResolvedValue({ prompts: [
      ...defaultPromptItems(),
      makePrompt({ key: 'literal', effective: literal, source: 'file' }),
      makePrompt({ key: 'missing-text', effective: '', source: 'missing' }),
    ] })
    render(html`<${PromptRegistryPanel} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')).not.toBeNull())
    const editor = container.querySelector('textarea') as HTMLTextAreaElement
    await fireEvent.input(editor, { target: { value: 'unsaved draft' } })
    const preview = container.querySelector('[data-prompt-preset-content]') as HTMLElement
    const toggle = preview.querySelector('button') as HTMLButtonElement
    expect(toggle.getAttribute('aria-expanded')).toBe('false')
    await fireEvent.click(toggle)
    expect(toggle.getAttribute('aria-expanded')).toBe('true')
    const literalContent = preview.querySelector('[data-preset-prompt="literal"] pre') as HTMLElement
    expect(literalContent.textContent).toBe(literal)
    expect(literalContent.tabIndex).toBe(0)
    expect(literalContent.getAttribute('role')).toBe('region')
    expect(literalContent.getAttribute('aria-label')).toBe('literal 원문')
    literalContent.focus()
    expect(document.activeElement).toBe(literalContent)
    expect(literalContent.classList.contains('focus-visible:outline-2')).toBe(true)
    const originalMembers = Array.from(preview.querySelectorAll('[data-preset-prompt]'))
      .map(member => member.getAttribute('data-preset-prompt'))
    const search = container.querySelector('input[aria-label="프롬프트 검색"]') as HTMLInputElement
    await fireEvent.input(search, { target: { value: 'analysis' } })
    expect(Array.from(preview.querySelectorAll('[data-preset-prompt]'))
      .map(member => member.getAttribute('data-preset-prompt'))).toEqual(originalMembers)
    await fireEvent.input(search, { target: { value: '' } })
    expect(preview.querySelector('script')).toBeNull()
    expect(preview.querySelector('[data-preset-prompt="missing-text"]')?.textContent).toContain('원문을 불러올 수 없습니다.')
    expect(preview.querySelector('[data-preset-prompt="keeper"] pre')?.textContent).toBe('override world')
    expect(preview.querySelector('[data-preset-prompt="keeper"]')?.textContent).toContain('기준 파일을 수정해도 오버라이드를 해제하기 전에는 이 원문이 유지됩니다.')
    expect(editor.value).toBe('unsaved draft')
    expect(mocks.savePromptOverride).not.toHaveBeenCalled()
    expect(mocks.clearPromptOverride).not.toHaveBeenCalled()
    const stage = Array.from(container.querySelectorAll('[data-prompt-preset-switcher] button'))
      .find(button => button.textContent?.includes('System rules')) as HTMLButtonElement
    await fireEvent.click(stage)
    expect(preview.querySelector('[data-preset-prompt="literal"]')).toBeNull()
    expect(preview.querySelector('[data-preset-prompt="keeper"] pre')?.textContent).toBe('override world')
    expect(editor.value).toBe('unsaved draft')
    await fireEvent.click(toggle)
    expect(preview.querySelector('pre')).toBeNull()
  })

  it('renders prompt metadata and switches the editor draft when selection changes', async () => {
    render(html`<${PromptRegistryPanel} />`, container)
    await flush()
    await flush()

    expect(mocks.fetchDashboardPrompts).toHaveBeenCalledTimes(1)
    expect(container.querySelector('.v2-lab-panel')).not.toBeNull()
    expect(container.querySelector('.v2-lab-row')).not.toBeNull()
    expect(container.textContent).toContain('프롬프트 레지스트리')
    expect(container.textContent).toContain('keeper')
    expect(container.textContent).toContain('fixture/config/prompts/keeper.md')
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

    const analysisButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('analysis.dry_run'),
    )
    analysisButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()

    expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toBe('dry run prompt')
  })

  it('previews a shipped language before saving only the keeper body', async () => {
    mocks.fetchDashboardPrompts.mockResolvedValue({ prompts: [
      ...defaultPromptItems(),
      makePrompt({ key: 'keeper.en', file_value: 'English instructions', effective: 'custom reference', source: 'override' }),
    ] })
    render(html`<${PromptRegistryPanel} />`, container)
    await flush()
    await flush()
    const english = Array.from(container.querySelectorAll('[data-keeper-prompt-language] button'))
      .find(button => button.textContent?.trim() === 'English') as HTMLButtonElement
    fireEvent.click(english)
    await flush()
    expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toBe('English instructions')
    expect(mocks.savePromptOverride).not.toHaveBeenCalled()
    expect(english.disabled).toBe(true)
    const save = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('오버라이드 적용')) as HTMLButtonElement
    fireEvent.click(save)
    await waitFor(() => expect(mocks.savePromptOverride).toHaveBeenCalledWith('keeper', 'English instructions'))
  })

  it('names the Librarian exact lane, effective prompt source, and every input section', async () => {
    render(html`<${PromptRegistryPanel} />`, container)
    await flush()
    await flush()

    const contract = container.querySelector('[data-librarian-runtime-contract]')
    expect(contract).not.toBeNull()
    expect(contract?.textContent).toContain('librarian_exact')
    expect(contract?.textContent).toContain('user message 한 개')
    expect(contract?.textContent).toContain('fixture/config/prompts/librarian.md')
    for (const input of [
      'keeper_instructions',
      'current_memory',
      'conversation_history',
      'counterpart_observations',
    ]) expect(contract?.textContent).toContain(input)

    const open = Array.from(contract?.querySelectorAll('button') ?? []).find(button =>
      button.textContent?.includes('effective 원문 열기'),
    ) as HTMLButtonElement
    await fireEvent.click(open)
    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement).value)
        .toContain('Keep {{current_memory}}')
    })
  })

  it('keeps curator and Librarian identities separate even when curator arrives first', async () => {
    mocks.fetchDashboardPrompts.mockResolvedValue({ prompts: [
      makePrompt({ key: 'workspace_memory_curator', category: 'librarian', source: 'override',
        effective: 'Curate {{workspace_memory_inventory}} with attribution',
        file_path: 'fixture/config/prompts/workspace_memory_curator.md',
        template_variables: ['workspace_memory_inventory'] }),
      ...defaultPromptItems(),
    ] })
    render(html`<${PromptRegistryPanel} />`, container)
    await flush()
    await flush()
    const librarian = container.querySelector('[data-librarian-runtime-contract]')
    expect(librarian?.textContent).toContain('fixture/config/prompts/librarian.md')
    expect(librarian?.textContent).not.toContain('workspace_memory_curator')
    const curator = container.querySelector('[data-workspace-curator-runtime-contract]')
    for (const field of ['workspace_curator_exact', 'workspace_memory_inventory', 'sources',
      'snapshots', 'gaps', 'model_proposed', 'keeper_workspace_memory_read', 'override']) {
      expect(curator?.textContent).toContain(field)
    }
    const open = curator?.querySelector('button') as HTMLButtonElement
    fireEvent.click(open)
    await waitFor(() => expect((container.querySelector('textarea') as HTMLTextAreaElement).value)
      .toBe('Curate {{workspace_memory_inventory}} with attribution'))
    expect(mocks.savePromptOverride).not.toHaveBeenCalled()
  })

  it('does not substitute a curator prompt for a missing Librarian prompt', async () => {
    mocks.fetchDashboardPrompts.mockResolvedValue({ prompts: [
      makePrompt({ key: 'workspace_memory_curator', category: 'librarian', effective: 'Curator body' }),
    ] })
    render(html`<${PromptRegistryPanel} />`, container)
    await flush()
    await flush()
    const librarian = container.querySelector('[data-librarian-runtime-contract]')
    expect(librarian?.textContent).toContain('librarian prompt 누락')
    expect(librarian?.querySelector('button')).toBeNull()
    expect(container.querySelector('[data-workspace-curator-runtime-contract] button')).not.toBeNull()
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
    expect(container.textContent).toContain('analysis.dry_run')
    expect(container.textContent).toContain('fixture/config/prompts/analysis.dry_run.md')
  })

  it('keeps dirty draft text across filters and confirms before discarding on row selection', async () => {
    render(html`<${PromptRegistryPanel} />`, container)
    await flush()
    await flush()

    const textarea = () => container.querySelector('textarea') as HTMLTextAreaElement
    const searchInput = () =>
      container.querySelector('input[aria-label="프롬프트 검색"]') as HTMLInputElement
    const analysisButton = () =>
      Array.from(container.querySelectorAll('button')).find(button =>
        button.textContent?.includes('analysis.dry_run'),
      ) as HTMLButtonElement | undefined

    await fireEvent.input(textarea(), { target: { value: 'edited unsaved draft' } })
    await fireEvent.input(searchInput(), { target: { value: 'analysis' } })
    await flush()

    expect(textarea().value).toBe('edited unsaved draft')

    const originalConfirm = window.confirm
    const confirmSpy = vi.fn(() => false)
    window.confirm = confirmSpy
    try {
      await fireEvent.click(analysisButton()!)
      await flush()

      expect(confirmSpy).toHaveBeenCalledTimes(1)
      expect(textarea().value).toBe('edited unsaved draft')

      confirmSpy.mockReturnValue(true)
      await fireEvent.click(analysisButton()!)
      await flush()

      expect(textarea().value).toBe('dry run prompt')
    } finally {
      window.confirm = originalConfirm
      await fireEvent.input(searchInput(), { target: { value: '' } })
    }
  })

  it.each([
    [{ status: 'queued' }, 'workspace curator 재확인 요청됨. 실행 완료는 아직 확인되지 않았습니다.'],
    [{ status: 'no_owner' }, '활성 workspace curator가 없어 재확인을 요청하지 못했습니다.'],
    [{ status: 'unavailable', detail: 'workspace unavailable' }, 'workspace curator 재확인 요청 실패: workspace unavailable'],
  ] as const)('shows the curator notification outcome after persistence: %s', async (refresh, expected) => {
    mocks.savePromptOverride.mockResolvedValueOnce({ ok: true, message: 'override set', curator_refresh: refresh })
    render(html`<${PromptRegistryPanel} />`, container)
    await flush()
    await flush()
    const applyButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('오버라이드 적용'),
    ) as HTMLButtonElement
    await fireEvent.click(applyButton)
    await waitFor(() => expect(container.textContent).toContain(expected))
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
      expect(mocks.savePromptOverride).toHaveBeenCalledWith('analysis.dry_run', 'dry run prompt')
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
