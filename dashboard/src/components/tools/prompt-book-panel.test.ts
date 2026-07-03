import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { DashboardPromptItem } from '../../api'
import { PromptBookPanel } from './prompt-book-panel'

function makePrompt(overrides: Partial<DashboardPromptItem> & { key: string }): DashboardPromptItem {
  return {
    category: 'keeper',
    description: '',
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

// Fixtures modelled on the real registry: a persona block with a body + vars, a
// dynamic_context block, and several non-keeper-turn families for the catalog.
const PROMPTS: DashboardPromptItem[] = [
  makePrompt({
    key: 'keeper.unified.system',
    category: 'keeper',
    description: '이름·역할·능력·담당',
    file_path: 'config/prompts/keeper.unified.system.md',
    effective: '{{identity_header}}\n## Where you live\n\nYou are a keeper inside `MASC`.',
    char_count: 120,
    template_variables: ['identity_header', 'goal_lines'],
  }),
  makePrompt({
    key: 'keeper.world',
    category: 'keeper',
    description: '샌드박스 경로·git 규칙',
    file_path: 'config/prompts/keeper.world.md',
    effective: '## Paths and Identity\n\nYour sandbox is the only filesystem ground you farm.',
    char_count: 80,
    template_variables: [],
  }),
  makePrompt({
    key: 'keeper.turn_intent.board_activity_guidance',
    category: 'keeper',
    description: 'board activity guidance',
    file_path: 'config/prompts/keeper.turn_intent.board_activity_guidance.md',
    char_count: 40,
  }),
  makePrompt({
    key: 'keeper.librarian.system',
    category: 'keeper',
    description: 'librarian system',
    file_path: 'config/prompts/keeper.librarian.system.md',
    char_count: 60,
  }),
  makePrompt({
    key: 'verification.action_verifier',
    category: 'verification',
    description: 'action verifier',
    file_path: 'config/prompts/verification.action_verifier.md',
    char_count: 50,
  }),
  makePrompt({
    key: 'dashboard.operator_judge',
    category: 'dashboard',
    description: 'operator judge',
    file_path: 'config/prompts/dashboard.operator_judge.md',
    char_count: 70,
  }),
  makePrompt({
    key: 'system.orchestrator',
    category: 'system',
    description: 'orchestrator',
    file_path: 'config/prompts/system.orchestrator.md',
    char_count: 30,
  }),
]

async function flush() {
  await new Promise(resolve => setTimeout(resolve, 0))
}

describe('PromptBookPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders the 9 canonical assembly blocks in order with live registry data', () => {
    render(html`<${PromptBookPanel} prompts=${PROMPTS} />`, container)

    const assembly = container.querySelector('[data-testid="prompt-book-assembly"]')
    expect(assembly).not.toBeNull()
    const chapters = container.querySelectorAll('[data-testid="pb-chapter"]')
    expect(chapters).toHaveLength(9)

    // first chapter is the always-on persona block; ordering follows Prompt_block_id.t
    const first = chapters[0]
    expect(first?.querySelector('.pb-ch-title')?.textContent).toBe('페르소나')
    // matched block surfaces the live char count + registry description as gloss
    expect(first?.textContent).toContain('120자')
    expect(first?.textContent).toContain('이름·역할·능력·담당')
    // a conditional block is tagged 조건부 (temporal_summary is always:false)
    expect(assembly?.textContent).toContain('조건부')
    // 2/9 blocks are matched by the fixture file_paths (persona + dynamic_context)
    expect(assembly?.textContent).toContain('2/9 블록')
  })

  it('expands a matched chapter to show the template body with {{var}} blanks, vars, and composed sources', async () => {
    render(html`<${PromptBookPanel} prompts=${PROMPTS} />`, container)

    const personaHead = container.querySelector('[data-block="persona"] .pb-ch-head') as HTMLButtonElement
    expect(personaHead).not.toBeNull()
    personaHead.click()
    await flush()

    const persona = container.querySelector('[data-block="persona"]')
    // body renders the live template heading + inline code
    expect(persona?.querySelector('.pb-ch-body')).not.toBeNull()
    expect(persona?.textContent).toContain('Where you live')
    expect(persona?.querySelector('.pb-code')?.textContent).toContain('MASC')
    // {{identity_header}} is an empty blank (no per-keeper substitution here)
    const blank = persona?.querySelector('.pb-blank')
    expect(blank?.textContent).toBe('identity_header')
    // template_variables + composed-from chips
    expect(persona?.textContent).toContain('template_variables')
    expect(persona?.textContent).toContain('goal_lines')
    expect(persona?.textContent).toContain('composed from')
    expect(persona?.textContent).toContain('keeper.capabilities.md')
  })

  it('shows a not-found note when a block has no matching registry prompt', async () => {
    // only the persona md is present — continuity/world/etc. are unmatched
    const onlyPersona = [PROMPTS[0]!]
    render(html`<${PromptBookPanel} prompts=${onlyPersona} />`, container)

    const continuityHead = container.querySelector('[data-block="continuity"] .pb-ch-head') as HTMLButtonElement
    continuityHead.click()
    await flush()

    const continuity = container.querySelector('[data-block="continuity"]')
    expect(continuity?.querySelector('.pb-ch-body')).toBeNull()
    expect(continuity?.textContent).toContain('원문을 찾지 못했습니다')
  })

  it('groups the full library into families with a keeper-turn vs separate split', async () => {
    render(html`<${PromptBookPanel} prompts=${PROMPTS} />`, container)

    const catalogTab = Array.from(container.querySelectorAll('.pb-seg-btn')).find(button =>
      button.textContent?.includes('전체 라이브러리'),
    ) as HTMLButtonElement
    catalogTab.click()
    await flush()

    const catalog = container.querySelector('[data-testid="prompt-book-catalog"]')
    expect(catalog).not.toBeNull()
    // total is the live prompt count, not a hardcoded fixture number
    expect(catalog?.textContent).toContain(`${PROMPTS.length}개 프롬프트`)

    const families = Array.from(catalog?.querySelectorAll('.pb-cat-fam') ?? [])
    const keeperFam = families.find(fam => fam.textContent?.includes('keeper 턴 · 조립'))
    expect(keeperFam?.classList.contains('feeds')).toBe(true)
    expect(keeperFam?.querySelector('.pb-cat-tag')?.textContent).toContain('keeper 턴')

    // separate (non-feeding) subsystems are classified before the generic keeper family
    const libFam = families.find(fam => fam.textContent?.includes('Librarian'))
    expect(libFam?.classList.contains('feeds')).toBe(false)
    expect(libFam?.textContent).toContain('별도 계열')
    expect(families.some(fam => fam.textContent?.includes('Verification'))).toBe(true)
    expect(families.some(fam => fam.textContent?.includes('Judge'))).toBe(true)
    expect(families.some(fam => fam.textContent?.includes('Orchestrator'))).toBe(true)

    // keeper turn family is displayed first (order 1)
    expect(families[0]?.textContent).toContain('keeper 턴 · 조립')
  })

  it('renders an empty state when no prompts are loaded', () => {
    render(html`<${PromptBookPanel} prompts=${[]} loading=${false} />`, container)
    expect(container.querySelector('[data-testid="prompt-book-panel"]')).not.toBeNull()
    expect(container.textContent).toContain('표시할 프롬프트가 없습니다')
    expect(container.querySelector('[data-testid="prompt-book-assembly"]')).toBeNull()
  })
})
