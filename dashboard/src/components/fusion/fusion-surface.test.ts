import { html } from 'htm/preact'
import { h, render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { BoardPost } from '../../types'
import { route } from '../../router'
import {
  fusionBoardLoading,
  fusionBoardPosts,
  fusionRuns,
  fusionRunsLoading,
  refreshFusionBoard,
  refreshFusionRuns,
} from '../../store'
import type { FusionJudgeNode } from '../../lib/fusion-meta'
import { FusionJudgesStrip, FusionSurface } from './fusion-surface'

// Mock only the refresh side effects; keep the real signals (fusionBoardLoading /
// fusionRunsLoading) via ...actual so the component reads live state. The manual
// Refresh button must fan out to BOTH refreshers — the run-status panel is a
// second data source the board-sink refresh cannot reach (RFC-0266 Phase 4).
vi.mock('../../store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../store')>()
  return { ...actual, refreshFusionBoard: vi.fn(), refreshFusionRuns: vi.fn() }
})

// The Markdown renderer is lazy-loaded, which makes synchronous assertions
// flaky inside the Fusion surface tests. Mock it to a synchronous renderer so
// we can assert that RichContent is used without waiting for the async chunk.
vi.mock('../common/markdown', () => ({
  Markdown: function Markdown(props: { text: string; class?: string }) {
    return h('div', { className: `markdown-content ${props.class ?? ''}`.trim() }, props.text)
  },
}))

function boardPost(overrides: Partial<BoardPost> & { id: string; meta: BoardPost['meta'] }): BoardPost {
  const { id, meta, ...rest } = overrides
  return {
    id,
    author: 'fusion-keeper',
    author_identity: {
      kind: 'keeper',
      id: 'fusion-keeper',
      key: 'keeper:fusion-keeper',
      display_name: 'Fusion Keeper',
      raw: 'fusion-keeper',
    },
    post_kind: 'automation',
    pinned: false,
    title: 'Fusion deliberation',
    body: 'Fusion body',
    content: 'Fusion content',
    meta,
    tags: [],
    votes: null,
    comment_count: 0,
    created_at: '2026-06-19T01:00:00Z',
    updated_at: '2026-06-19T01:02:00Z',
    ...rest,
  }
}

describe('FusionSurface', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    window.location.hash = '#fusion'
    route.value = { tab: 'fusion', params: {}, postId: null }
    fusionBoardLoading.value = false
    fusionBoardPosts.value = []
    fusionRuns.value = []
    fusionRunsLoading.value = false
    vi.mocked(refreshFusionBoard).mockClear()
    vi.mocked(refreshFusionRuns).mockClear()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    fusionBoardLoading.value = false
    fusionBoardPosts.value = []
    fusionRuns.value = []
    fusionRunsLoading.value = false
    route.value = { tab: 'overview', params: {}, postId: null }
    window.location.hash = '#overview'
  })

  it('renders live top-level fusion board metadata', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-fus-1',
        title: 'Fusion deliberation (run fus-1): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-1',
          question: 'Which deploy path should we take?',
          panel: [
            {
              model: 'gpt-5',
              status: 'answered',
              answer: 'Use the canary path.',
              input_tokens: 1200,
              output_tokens: 340,
            },
            {
              model: 'claude-sonnet-4',
              status: 'failed',
              reason: 'timeout',
            },
          ],
          judge: {
            status: 'synthesized',
            decision: 'answer',
            synthesis: 'Canary has the best rollback evidence.',
            resolved_answer: 'Ship canary first, then expand.',
          },
          observed_usage: {
            input_tokens: 1300,
            output_tokens: 360,
          },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    expect(container.querySelector('[data-testid="fusion-surface"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="fusion-reality-notice"]')?.textContent)
      .toContain('부분 지원')
    expect(container.querySelector('[data-testid="fusion-reality-notice"]')?.textContent)
      .toContain('fail-closed')
    expect(container.textContent).toContain('fus-1')
    expect(container.textContent).toContain('Which deploy path should we take?')
    expect(container.textContent).toContain('gpt-5')
    expect(container.textContent).toContain('claude-sonnet-4')
    // The rebuilt detail surfaces the judge verdict as the humanized decision
    // label ('answer' -> '해결 답안' via fusionDecisionSpec), then renders
    // `resolved_answer` as the resolved body. The raw `judge.synthesis` string is
    // only a fallback for `resolved_answer` (FusionRunDetail `resolved = ...`), so
    // it is not shown when `resolved_answer` is present — assert the verdict the
    // component actually renders from this judge metadata instead.
    expect(container.textContent).toContain('해결 답안')
    expect(container.textContent).toContain('Ship canary first, then expand.')
    // Tokens are no longer rendered as separate comma-formatted in/out figures;
    // the detail KPI strip combines panel+judge into one `Nk` total
    // (combinedTokenLabel: observed 1300 + 360 = 1660 -> '1.7k').
    expect(container.textContent).toContain('토큰 (패널+심판)')
    expect(container.textContent).toContain('1.7k')
    expect(container.querySelector('[data-testid="fusion-pipe"]')).not.toBeNull()
    expect(container.querySelector('.fus-rdot.done')).not.toBeNull()
    expect(container.textContent).toContain('panel ×2')
    expect(container.textContent).toContain('board evidence')
    expect(container.textContent).not.toContain('chat · board')
  })

  it('renders the RFC-0284 judge-node strip for a judge-of-judges run', () => {
    // Wiring pin: a board post carrying the `judges` observation array must
    // surface the per-node topology in the detail view. Before RFC-0284 PR 2
    // the backend emitted this array but the dashboard dropped it (collapsed to
    // the singular judge) — this test red-guards that silent regression.
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-joj',
        title: 'Fusion deliberation (run joj-1): answer',
        meta: {
          source: 'fusion',
          run_id: 'joj-1',
          question: 'Which judge topology?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'a' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'reconciled answer' },
          judges: [
            { role: 'first', identity: 'gpt-4o', input_tokens: 100, output_tokens: 10 },
            { role: 'first', identity: 'gemini', status: 'failed', error: 'timeout', input_tokens: 5, output_tokens: 0 },
            { role: 'meta', identity: 'o1', input_tokens: 2000, output_tokens: 418 },
          ],
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const strip = container.querySelector('[data-testid="fusion-judges"]')
    expect(strip).not.toBeNull()
    expect(strip?.querySelectorAll('li')).toHaveLength(3)
    // shape-derived header + role badges (topology is read from the array shape)
    expect(container.textContent).toContain('심판의 심판')
    expect(container.textContent).toContain('1차')
    expect(container.textContent).toContain('메타')
    // a failed first-judge node is marked, not dropped
    expect(
      container.querySelector('[data-testid="fusion-judges"] [data-failed="true"]'),
    ).not.toBeNull()
    // the canonical synthesis below the strip is unchanged
    expect(container.textContent).toContain('reconciled answer')
  })

  it('renders structured judge evidence from board metadata without local prototype state', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-fus-structured',
        title: 'Fusion deliberation (run fus-structured): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-structured',
          question: 'Which model result should drive the operator note?',
          panel: [
            { model: 'gpt-5', status: 'answered', answer: 'Prefer the canary-backed note.' },
            { model: 'glm-5', status: 'answered', answer: 'Mention rollback uncertainty.' },
          ],
          judge: {
            status: 'synthesized',
            decision: 'recommend',
            synthesis: 'Most models prefer canary with a rollback caveat.',
            resolved_answer: 'Use canary, but call out rollback coverage.',
            consensus: [
              { text: 'Canary rollout is the safer next step.', models: ['gpt-5', 'glm-5'] },
            ],
            contradictions: [
              {
                topic: 'rollback confidence',
                positions: [
                  ['gpt-5', 'rollback path is sufficiently tested'],
                  ['glm-5', 'rollback proof is still thin'],
                ],
              },
            ],
            partial_coverage: [
              {
                topic: 'mobile operators',
                addressed_by: ['glm-5'],
                missing: 'No model checked low-bandwidth mobile review.',
              },
            ],
            unique_insights: [
              { model: 'glm-5', text: 'Add the rollback caveat to the operator note.' },
            ],
            blind_spots: ['No cost impact estimate.'],
            missing: ['staging rollback transcript'],
            recommend: {
              action: 'publish operator note',
              rationale: 'The panel converged after preserving the caveat.',
            },
          },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const evidence = container.querySelector('[data-testid="fusion-judge-evidence"]')
    expect(evidence).not.toBeNull()
    expect(evidence?.textContent).toContain('Structured judge evidence')
    expect(evidence?.textContent).toContain('Canary rollout is the safer next step.')
    expect(evidence?.textContent).toContain('rollback confidence')
    expect(evidence?.textContent).toContain('rollback proof is still thin')
    expect(evidence?.textContent).toContain('No model checked low-bandwidth mobile review.')
    expect(evidence?.textContent).toContain('Add the rollback caveat to the operator note.')
    expect(evidence?.textContent).toContain('No cost impact estimate.')
    expect(evidence?.textContent).toContain('staging rollback transcript')
    // The recommendation `action` is rendered in the `.fus-resolved` block as
    // `권고 · <action>` (FusionRunDetail), not inside the structured judge-evidence
    // panel — assert it against the full surface where it actually appears.
    expect(container.textContent).toContain('publish operator note')
  })

  it('calls ringFocusClasses() for focus rings instead of stringifying the function', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-fus-1',
        title: 'Fusion deliberation (run fus-1): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-1',
          question: 'Which deploy path should we take?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'Use the canary path.' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Ship canary first.' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    // Regression guard: a bare `${ringFocusClasses}` interpolation coerces the
    // function to its source text (which contains the `opts` parameter) into the
    // class attribute, so the resolved focus-ring utilities are never applied.
    const refresh = container.querySelector<HTMLButtonElement>('.fus-refresh')
    expect(refresh).not.toBeNull()
    expect(refresh?.className).toContain('focus-visible:outline-none')
    expect(refresh?.className).not.toContain('opts')

    const row = container.querySelector<HTMLButtonElement>('.fus-run-row')
    expect(row).not.toBeNull()
    expect(row?.className).toContain('focus-visible:outline-none')
    expect(row?.className).not.toContain('opts')
  })

  it('supports older nested fusion_deliberation metadata and route selection', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-fus-1',
        updated_at: '2026-06-19T01:00:00Z',
        meta: {
          fusion_deliberation: {
            run_id: 'fus-1',
            question: 'older run',
            panel: [],
            judge: { status: 'synthesized', resolved_answer: 'older answer' },
          },
        },
      }),
      boardPost({
        id: 'post-fus-2',
        updated_at: '2026-06-19T02:00:00Z',
        meta: {
          fusion_deliberation: {
            run_id: 'fus-2',
            question: 'newer run',
            panel: [],
            judge: { status: 'synthesized', resolved_answer: 'newer answer' },
          },
        },
      }),
    ]
    route.value = { tab: 'fusion', params: { run_id: 'fus-1' }, postId: null }

    render(html`<${FusionSurface} />`, container)

    expect(container.querySelector('[data-testid="fusion-detail"]')?.textContent).toContain('older answer')

    const secondRow = Array.from(container.querySelectorAll<HTMLButtonElement>('.fus-run-row'))
      .find(button => button.textContent?.includes('fus-2'))
    expect(secondRow).not.toBeUndefined()
    secondRow?.click()

    expect(route.value.tab).toBe('fusion')
    expect(route.value.params).toEqual({ run_id: 'fus-2' })
    expect(window.location.hash).toBe('#fusion?run_id=fus-2')
  })

  it('shows a board-sink empty state when no fusion board posts are loaded', () => {
    render(html`<${FusionSurface} />`, container)

    expect(container.querySelector('[data-testid="fusion-empty"]')).not.toBeNull()
    expect(container.textContent).toContain('No board-sink fusion posts yet')
    expect(container.textContent).toContain('/api/v1/dashboard/fusion-runs')
  })

  it('keeps registry-only running rows visible without claiming no fusion runs exist', () => {
    fusionRuns.value = [
      {
        runId: 'fus-running',
        keeper: 'sangsu',
        preset: 'balanced',
        startedAt: 1_780_000_000,
        status: 'running',
      },
    ]

    render(html`<${FusionSurface} />`, container)

    expect(container.querySelector('[data-testid="fusion-run-status-card"]')?.textContent).toContain('fus-running')
    expect(container.querySelector('[data-testid="fusion-empty"]')?.textContent).toContain('No board-sink fusion posts yet')
    expect(container.textContent).toContain('board runs')
    expect(container.textContent).toContain('registry')
    expect(container.textContent).toContain('1 running')
    expect(container.textContent).not.toContain('No fusion runs found')
  })

  it('renders preset from registry when board meta does not carry it', () => {
    fusionRuns.value = [
      {
        runId: 'fus-1',
        keeper: 'sangsu',
        preset: 'balanced',
        startedAt: 1_780_000_000,
        status: 'running',
      },
    ]
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-fus-1',
        title: 'Fusion deliberation (run fus-1): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-1',
          question: 'Which path?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'Canary.' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Ship canary.' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const detail = container.querySelector('[data-testid="fusion-detail"]')
    expect(detail?.textContent).toContain('preset · balanced')
    expect(detail?.textContent).not.toContain('preset · n/a')
  })

  it('manual Refresh fans out to both the board-meta detail and the run-status registry', () => {
    render(html`<${FusionSurface} />`, container)
    const refresh = container.querySelector<HTMLButtonElement>('.fus-refresh')
    expect(refresh).not.toBeNull()
    refresh?.click()
    // The run-status panel reads the fusionRuns signal, a source refreshFusionBoard
    // never touches; the button must trigger refreshFusionRuns too.
    expect(vi.mocked(refreshFusionBoard)).toHaveBeenCalledTimes(1)
    expect(vi.mocked(refreshFusionRuns)).toHaveBeenCalledTimes(1)
  })

  it('disables Refresh while the run registry is loading even when the board is idle', () => {
    fusionRunsLoading.value = true
    render(html`<${FusionSurface} />`, container)
    const refresh = container.querySelector<HTMLButtonElement>('.fus-refresh')
    expect(refresh?.disabled).toBe(true)
    expect(refresh?.textContent).toContain('Refreshing')
  })

  it('counts only explicit panel failure statuses, not substrings like failover', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-fus-statuses',
        title: 'Fusion deliberation (run fus-statuses): mixed',
        meta: {
          source: 'fusion',
          run_id: 'fus-statuses',
          question: 'Status edge cases?',
          panel: [
            { model: 'm1', status: 'failover', answer: 'Not a failure.' },
            { model: 'm2', status: 'error', reason: 'provider error' },
          ],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'One real failure.' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const detail = container.querySelector('[data-testid="fusion-detail"]')
    // Only the explicit 'error' status counts as failed; 'failover' is treated as answered.
    expect(detail?.textContent).toContain('1/2')
    expect(detail?.textContent).toContain('fail 1')
    expect(detail?.textContent).not.toContain('0/2')
    expect(detail?.textContent).not.toContain('fail 2')

    const cards = container.querySelectorAll('.fus-panel-card')
    expect(cards[0]?.classList.contains('answered')).toBe(true)
    expect(cards[0]?.classList.contains('failed')).toBe(false)
    expect(cards[1]?.classList.contains('failed')).toBe(true)
  })

  it('renders generation parameters when present in board meta', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-params',
        title: 'Fusion deliberation (run fus-params): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-params',
          question: 'Which path?',
          temperature: 0.7,
          top_p: 0.95,
          top_k: 40,
          max_tokens: 2048,
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'Canary.' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Ship canary.' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const detail = container.querySelector('[data-testid="fusion-detail"]')
    expect(detail?.textContent).toContain('temperature')
    expect(detail?.textContent).toContain('0.7')
    expect(detail?.textContent).toContain('top_p')
    expect(detail?.textContent).toContain('0.95')
    expect(detail?.textContent).toContain('top_k')
    expect(detail?.textContent).toContain('40')
    expect(detail?.textContent).toContain('max_tokens')
    expect(detail?.textContent).toContain('2048')
  })

  it('hides the generation parameters block when no params are present', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-no-params',
        title: 'Fusion deliberation (run fus-no-params): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-no-params',
          question: 'Which path?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'Canary.' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Ship canary.' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const detail = container.querySelector('[data-testid="fusion-detail"]')
    expect(detail?.textContent).not.toContain('생성 파라미터')
  })

  it('renders the deliberation prompt as rich content', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-rich-prompt',
        title: 'Fusion deliberation (run fus-rich-prompt): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-rich-prompt',
          question: 'Check **this** [link](https://example.com).',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'OK.' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Done.' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const prompt = container.querySelector('[data-testid="fusion-detail"] .fus-prompt')
    expect(prompt?.querySelector('.markdown-content')).not.toBeNull()
    expect(prompt?.textContent).toContain('this')
    expect(prompt?.textContent).toContain('link')
  })

  it('renders panel answers as rich content', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-rich-panel',
        title: 'Fusion deliberation (run fus-rich-panel): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-rich-panel',
          question: 'Which path?',
          panel: [
            {
              model: 'gpt-5',
              status: 'answered',
              answer: 'Use **canary** first.',
            },
          ],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Ship canary.' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const panel = container.querySelector('.fus-panel-card')
    expect(panel?.querySelector('.markdown-content')).not.toBeNull()
    expect(panel?.textContent).toContain('canary')
  })

  it('renders judge evidence text as rich content', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-rich-judge',
        title: 'Fusion deliberation (run fus-rich-judge): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-rich-judge',
          question: 'Which path?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'Canary.' }],
          judge: {
            status: 'synthesized',
            decision: 'answer',
            resolved_answer: 'Ship canary.',
            consensus: [{ text: '**Canary** is safer.', models: ['gpt-5'] }],
          },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const evidence = container.querySelector('[data-testid="fusion-judge-evidence"]')
    expect(evidence?.querySelector('.markdown-content')).not.toBeNull()
    expect(evidence?.textContent).toContain('Canary')
  })

  it('renders resolved answer and recommendation rationale as rich content', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-rich-resolved',
        title: 'Fusion deliberation (run fus-rich-resolved): recommend',
        meta: {
          source: 'fusion',
          run_id: 'fus-rich-resolved',
          question: 'Which path?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'Canary.' }],
          judge: {
            status: 'synthesized',
            decision: 'recommend',
            resolved_answer: 'Ship **canary**.',
            recommend: {
              action: 'publish note',
              rationale: 'Because **rollback** is covered.',
            },
          },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const resolved = container.querySelector('.fus-resolved-body')
    expect(resolved?.querySelector('.markdown-content')).not.toBeNull()
    expect(resolved?.textContent).toContain('canary')

    const rationale = container.querySelector('.fus-rec-rationale')
    expect(rationale?.querySelector('.markdown-content')).not.toBeNull()
    expect(rationale?.textContent).toContain('rollback')
  })
})

describe('FusionJudgesStrip', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  // meta/single/refine echo their role as identity (fusion_sink judge_role_fields);
  // only `first` carries a real panelist id.
  const nodes: FusionJudgeNode[] = [
    { role: 'first', identity: 'gpt-4o', failed: false, inputTokens: 100, outputTokens: 10 },
    { role: 'first', identity: 'gemini', failed: true, error: 'timeout', inputTokens: 5, outputTokens: 0 },
    { role: 'meta', identity: 'meta', failed: false, inputTokens: 2000, outputTokens: 418 },
  ]

  it('renders one row per node with role/failed data attributes and the token label', () => {
    render(html`<${FusionJudgesStrip} nodes=${nodes} />`, container)
    const items = container.querySelectorAll('[data-testid="fusion-judges"] li')
    expect(items).toHaveLength(3)
    expect(items[0]?.getAttribute('data-role')).toBe('first')
    expect(items[0]?.getAttribute('data-failed')).toBe('false')
    expect(items[1]?.getAttribute('data-failed')).toBe('true')
    expect(items[2]?.getAttribute('data-role')).toBe('meta')
    // 2000 + 418 = 2418 -> 2.4k tok
    expect(container.textContent).toContain('2.4k tok')
    const failed = container.querySelector('[data-failed="true"] .fus-jn-status')
    expect(failed?.getAttribute('title')).toBe('timeout')
    expect(failed?.textContent).toContain('실패')
  })

  it('shows a panelist id for first nodes but suppresses the role-echo identity of a meta node', () => {
    render(html`<${FusionJudgesStrip} nodes=${nodes} />`, container)
    const items = container.querySelectorAll('[data-testid="fusion-judges"] li')
    expect(items[0]?.querySelector('.fus-jn-id')?.textContent?.trim()).toBe('gpt-4o')
    // meta identity === role ('meta') is redundant with the badge, so it is blank
    expect(items[2]?.querySelector('.fus-jn-id')?.textContent?.trim()).toBe('')
  })

  it('renders nothing for a board post that predates the judges array', () => {
    render(html`<${FusionJudgesStrip} nodes=${[]} />`, container)
    expect(container.querySelector('[data-testid="fusion-judges"]')).toBeNull()
  })
})
