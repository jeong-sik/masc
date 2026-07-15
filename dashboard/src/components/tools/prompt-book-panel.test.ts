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

// Fixtures modelled on the real registry: keeper-turn md files plus several
// non-keeper-turn families. Includes keeper.recovery_block.md — a file the
// removed BLOCK_SPEC had mapped to the dynamic retry_nudge/temporal_summary
// runtime blocks — to guard it now appears only as a catalog file, never as a
// Prompt_block_id block body.
const PROMPTS: DashboardPromptItem[] = [
  makePrompt({
    key: 'keeper.unified.system',
    category: 'keeper',
    description: '이름·역할·능력·담당',
    file_path: 'config/prompts/keeper.unified.system.md',
    effective: '{{identity_header}}\n## Where you live\n\nYou are a keeper inside MASC.',
    char_count: 120,
    template_variables: ['identity_header', 'instructions'],
  }),
  makePrompt({
    key: 'keeper.recovery_block',
    category: 'keeper',
    description: 'recovery block',
    file_path: 'config/prompts/keeper.recovery_block.md',
    effective: 'recovery guard body',
    char_count: 80,
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

  it('groups the prompt library into families with a keeper-turn vs separate split', () => {
    render(html`<${PromptBookPanel} prompts=${PROMPTS} />`, container)

    const catalog = container.querySelector('[data-testid="prompt-book-catalog"]')
    expect(catalog).not.toBeNull()
    // total is the live prompt count, not a hardcoded fixture number
    expect(catalog?.textContent).toContain(`${PROMPTS.length}개 프롬프트`)
    // the family split and keeper-turn flag are labelled as client curation
    expect(catalog?.textContent).toContain('클라이언트 큐레이션')

    const families = Array.from(catalog?.querySelectorAll('.pb-cat-fam') ?? [])
    const keeperFam = families.find(fam => fam.textContent?.includes('keeper 턴'))
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
    expect(families[0]?.textContent).toContain('keeper 턴 · 계열')
  })

  it('does not present any Prompt_block_id block provenance or a markdown-file block body', () => {
    // Regression guard (review #23052): the removed BLOCK_SPEC mapped dynamic
    // runtime blocks (retry_nudge / temporal_summary) to keeper.recovery_block.md
    // and rendered that md as the block body — fabricated provenance. The library
    // must present that file only as a catalog chip, never as a block with a body.
    render(html`<${PromptBookPanel} prompts=${PROMPTS} />`, container)

    expect(container.querySelector('[data-testid="prompt-book-assembly"]')).toBeNull()
    expect(container.querySelector('[data-block]')).toBeNull()
    expect(container.querySelector('.pb-ch-body')).toBeNull()
    // no Prompt_block_id assembly-order / block-count product copy
    expect(container.textContent).not.toContain('Prompt_block_id')
    expect(container.textContent).not.toContain('조립 블록')
    // the recovery-block md still appears, but only as a catalog file chip
    const chip = Array.from(container.querySelectorAll('.pb-src-chip')).find(el =>
      el.textContent?.includes('keeper.recovery_block.md'),
    )
    expect(chip).toBeTruthy()
    // and its body text is never surfaced as a rendered block
    expect(container.textContent).not.toContain('recovery guard body')
  })

  it('renders an empty state when no prompts are loaded', () => {
    render(html`<${PromptBookPanel} prompts=${[]} loading=${false} />`, container)
    expect(container.querySelector('[data-testid="prompt-book-panel"]')).not.toBeNull()
    expect(container.textContent).toContain('표시할 프롬프트가 없습니다')
    expect(container.querySelector('[data-testid="prompt-book-catalog"]')).toBeNull()
  })
})
