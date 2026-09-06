import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { DashboardPromptItem, DashboardRuntimePromptAsset } from '../../api'
import { PromptBookPanel } from './prompt-book-panel'

function makePrompt(overrides: Partial<DashboardPromptItem> & { key: string }): DashboardPromptItem {
  return {
    category: 'keeper',
    description: '',
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

// Exact current managed assets. Category comes from each file's frontmatter and
// is the sole family SSOT; key/file-name substrings never classify a prompt.
const PROMPTS: DashboardPromptItem[] = [
  makePrompt({
    key: 'keeper',
    category: 'keeper',
    description: 'Keeper standing rules',
    file_path: 'config/prompts/keeper.md',
    effective: 'Inspect current typed state and act on justified work.',
    char_count: 120,
    template_variables: [],
  }),
  makePrompt({
    key: 'judge.board',
    category: 'judge',
    description: 'Board relevance judge',
    file_path: 'config/prompts/judge.board.md',
    char_count: 80,
  }),
  makePrompt({
    key: 'librarian',
    category: 'librarian',
    description: 'Current-memory selector',
    file_path: 'config/prompts/librarian.md',
    char_count: 60,
  }),
  makePrompt({
    key: 'verification',
    category: 'verification',
    description: 'anti-rationalization guidance',
    file_path: 'config/prompts/verification.md',
    char_count: 50,
  }),
]

const RUNTIME_ASSETS: DashboardRuntimePromptAsset[] = [
  {
    path: 'keeper.autonomous.wake.txt',
    file_path: 'config/prompts/keeper.autonomous.wake.txt',
    value: 'Choose the next justified task.',
    file_exists: true,
    char_count: 31,
  },
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

    // Separate subsystem categories never feed the Keeper turn.
    const libFam = families.find(fam => fam.textContent?.includes('Librarian'))
    expect(libFam?.classList.contains('feeds')).toBe(false)
    expect(libFam?.textContent).toContain('별도 계열')
    expect(families.some(fam => fam.textContent?.includes('Verification'))).toBe(true)
    expect(families.some(fam => fam.textContent?.includes('Judge'))).toBe(true)

    // keeper turn family is displayed first (order 1)
    expect(families[0]?.textContent).toContain('keeper 턴 · 계열')
  })

  // Every asset config/prompts actually ships must land in the family named by
  // its frontmatter category.
  it('classifies every shipped prompt asset into a named family', () => {
    const SHIPPED = [
      { key: 'keeper', category: 'keeper' },
      { key: 'judge.board', category: 'judge' },
      { key: 'judge.effect', category: 'judge' },
      { key: 'librarian', category: 'librarian' },
      { key: 'verification', category: 'verification' },
      { key: 'keeper.canary.recall', category: 'canary' },
      { key: 'keeper.capability_probe', category: 'probe' },
      { key: 'mcp.full', category: 'mcp' },
      { key: 'eval.calibration.few_shot', category: 'evaluation' },
    ]
    render(
      html`<${PromptBookPanel}
        prompts=${SHIPPED.map(({ key, category }) =>
          makePrompt({ key, category, file_path: `config/prompts/${key}.md`, char_count: 10 }),
        )}
      />`,
      container,
    )
    const catalog = container.querySelector('[data-testid="prompt-book-catalog"]')
    const families = Array.from(catalog?.querySelectorAll('.pb-cat-fam') ?? [])
    expect(families.some(fam => fam.textContent?.includes('Other'))).toBe(false)
    expect(families.some(fam => fam.textContent?.includes('keeper 턴'))).toBe(true)
  })

  it('shows raw runtime assets separately and read-only', () => {
    render(html`<${PromptBookPanel} prompts=${PROMPTS} runtimeAssets=${RUNTIME_ASSETS} />`, container)

    const assets = container.querySelector('[data-testid="prompt-book-runtime-assets"]')
    expect(assets).not.toBeNull()
    expect(assets?.textContent).toContain('읽기 전용')
    expect(assets?.textContent).toContain('keeper.autonomous.wake.txt')
    expect(assets?.textContent).toContain('Choose the next justified task.')
    expect(assets?.textContent).toContain('override 대상이 아닙니다')
  })

  it('keeps runtime assets visible when the Markdown registry is empty', () => {
    render(html`<${PromptBookPanel} prompts=${[]} runtimeAssets=${RUNTIME_ASSETS} />`, container)

    expect(container.querySelector('[data-testid="prompt-book-catalog"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="prompt-book-runtime-assets"]')).not.toBeNull()
    expect(container.textContent).not.toContain('표시할 프롬프트 없음')
  })

  it('does not present Prompt_block_id assembly provenance', () => {
    render(html`<${PromptBookPanel} prompts=${PROMPTS} />`, container)

    expect(container.querySelector('[data-testid="prompt-book-assembly"]')).toBeNull()
    expect(container.querySelector('[data-block]')).toBeNull()
    expect(container.querySelector('.pb-ch-body')).toBeNull()
    // no Prompt_block_id assembly-order / block-count product copy
    expect(container.textContent).not.toContain('Prompt_block_id')
    expect(container.textContent).not.toContain('조립 블록')
  })

  it('does not infer a family from key or file-name substrings', () => {
    render(html`<${PromptBookPanel} prompts=${[
      makePrompt({
        key: 'housekeeper.judge-lookalike',
        category: 'protocol-drift',
        file_path: 'config/prompts/judge-but-not-category.md',
      }),
    ]} />`, container)
    expect(container.textContent).toContain('Other · 기타')
    expect(container.textContent).not.toContain('keeper 턴 · 계열')
    expect(container.textContent).not.toContain('Judge')
  })

  it('renders an empty state when no prompts are loaded', () => {
    render(html`<${PromptBookPanel} prompts=${[]} loading=${false} />`, container)
    expect(container.querySelector('[data-testid="prompt-book-panel"]')).not.toBeNull()
    expect(container.textContent).toContain('표시할 프롬프트 없음')
    expect(container.querySelector('[data-testid="prompt-book-catalog"]')).toBeNull()
  })
})
