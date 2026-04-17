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

import type { DashboardPromptItem } from '../../api'
import { PromptRegistryPanel, filterPrompts, promptSourceCounts } from './prompt-registry-panel'

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

describe('filterPrompts', () => {
  it('returns all prompts when source is all and query is empty', () => {
    expect(filterPrompts(HELPER_FIXTURES, 'all', '')).toHaveLength(5)
  })

  it('filters by source', () => {
    const file = filterPrompts(HELPER_FIXTURES, 'file', '')
    expect(file).toHaveLength(2)
    expect(file.every(p => p.source === 'file')).toBe(true)
    expect(filterPrompts(HELPER_FIXTURES, 'override', '')).toHaveLength(1)
    expect(filterPrompts(HELPER_FIXTURES, 'missing', '')).toHaveLength(1)
    expect(filterPrompts(HELPER_FIXTURES, 'default', '')).toHaveLength(1)
  })

  it('search matches key substring (case-insensitive)', () => {
    const out = filterPrompts(HELPER_FIXTURES, 'all', 'KEEPER')
    expect(out.map(p => p.key)).toEqual(['keeper.system', 'keeper.turn'])
  })

  it('search matches category', () => {
    expect(filterPrompts(HELPER_FIXTURES, 'all', 'planner')).toHaveLength(2)
  })

  it('search matches description', () => {
    const out = filterPrompts(HELPER_FIXTURES, 'all', 'briefing')
    expect(out).toHaveLength(1)
    expect(out[0]?.key).toBe('supervisor.brief')
  })

  it('source and query combine with AND', () => {
    const out = filterPrompts(HELPER_FIXTURES, 'file', 'keeper')
    expect(out).toHaveLength(1)
    expect(out[0]?.key).toBe('keeper.system')
  })

  it('whitespace-only query is treated as empty', () => {
    expect(filterPrompts(HELPER_FIXTURES, 'all', '   ')).toHaveLength(5)
  })

  it('returns empty when nothing matches', () => {
    expect(filterPrompts(HELPER_FIXTURES, 'all', 'no-such-key')).toEqual([])
  })
})

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
