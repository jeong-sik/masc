import { html } from 'htm/preact'
import { h, render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { BoardPost } from '../../types'
import { route } from '../../router'
import {
  fusionBoardError,
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
    origin: null,
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
    fusionBoardError.value = null
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
    fusionBoardError.value = null
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
        origin: {
          source: 'fusion',
          fusion_run_id: 'fus-1',
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
    expect(container.querySelector('[data-testid="fusion-sink-linkage"]')?.getAttribute('data-linkage-status')).toBe('verified')
    expect(container.querySelector('[data-testid="fusion-sink-correlation"]')?.getAttribute('data-meta-run-id')).toBe('fus-1')
    expect(container.querySelector('[data-testid="fusion-sink-correlation"]')?.getAttribute('data-origin-run-id')).toBe('fus-1')
    expect(container.textContent).toContain('origin verified')
    expect(container.textContent).toContain('typed origin으로 run linkage 검증')
    expect(container.textContent).not.toContain('chat · board')
  })

  it('warns when a successful fusion board post lacks typed origin linkage', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-fus-legacy',
        title: 'Fusion deliberation (run fus-legacy): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-legacy',
          question: 'Legacy sink?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'Use meta only.' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Legacy answer.' },
        },
        origin: null,
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const linkage = container.querySelector('[data-testid="fusion-sink-linkage"]')
    const correlation = container.querySelector('[data-testid="fusion-sink-correlation"]')
    expect(linkage?.getAttribute('data-linkage-status')).toBe('missing')
    expect(linkage?.textContent).toContain('origin unverified')
    expect(linkage?.textContent).toContain('typed board origin is absent')
    expect(correlation?.getAttribute('data-origin-run-id')).toBe('')
    expect(correlation?.textContent).toContain('origin unverified')
  })

  it('flags a meta/origin run-id mismatch instead of treating sink projection as verified', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-fus-drift',
        title: 'Fusion deliberation (run fus-meta): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-meta',
          question: 'Drifted sink?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'Mismatch.' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Mismatch answer.' },
        },
        origin: {
          source: 'fusion',
          fusion_run_id: 'fus-origin',
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const linkage = container.querySelector('[data-testid="fusion-sink-linkage"]')
    const correlation = container.querySelector('[data-testid="fusion-sink-correlation"]')
    expect(linkage?.getAttribute('data-linkage-status')).toBe('mismatch')
    expect(linkage?.textContent).toContain('origin mismatch')
    expect(linkage?.textContent).toContain('origin.fusion_run_id=fus-origin')
    expect(correlation?.getAttribute('data-meta-run-id')).toBe('fus-meta')
    expect(correlation?.getAttribute('data-origin-run-id')).toBe('fus-origin')
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

  it('branches the pipeline strip and meta block for a judge-of-judges run with an isolated 1차 심판', () => {
    // A JoJ run with 3 first judges (one failed) + a meta node: the pipeline
    // shows `1차 심판 ×3 (1 격리) → meta` and the meta block a reconcile label +
    // isolation banner. All shape-derived from the judges array (no topology wire
    // field, and no locally-invented topology vocabulary).
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-joj-iso',
        title: 'Fusion deliberation (run joj-iso): answer',
        meta: {
          source: 'fusion',
          run_id: 'joj-iso',
          question: 'Which redesign?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'a' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'reconciled answer' },
          judges: [
            { role: 'first', identity: 'deepseek-v4-pro', input_tokens: 100, output_tokens: 10 },
            { role: 'first', identity: 'glm-5', input_tokens: 90, output_tokens: 8 },
            { role: 'first', identity: 'minimax-m3', status: 'failed', error: 'Timeout' },
            { role: 'meta', identity: 'meta', input_tokens: 2000, output_tokens: 418 },
          ],
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    // pipeline: shape-derived JoJ segment with the isolation count and meta node
    const pipe = container.querySelector('[data-testid="fusion-pipe"]')
    expect(pipe?.textContent).toContain('1차 심판 ×3')
    expect(pipe?.querySelector('.fus-pipe-iso')?.textContent).toContain('1 격리')
    expect(pipe?.querySelector('.fus-pipe-node.meta')?.textContent).toContain('meta')

    // no locally-pinned topology vocabulary chip/tag (removed per review #23049 —
    // shape stays surfaced via the SSOT judge-node strip + pipeline branch)
    const detail = container.querySelector('[data-testid="fusion-detail"]')
    expect(container.querySelector('.fus-topo')).toBeNull()
    expect(container.querySelector('.fus-row-topo')).toBeNull()

    // meta block reconcile label (okFirstCount = 2) + isolation banner
    expect(detail?.textContent).toContain('meta 심판 · reconcile')
    expect(detail?.textContent).toContain('1차 종합 2개 reconcile')
    const drop = detail?.querySelector('.fus-meta-drop')
    expect(drop?.textContent).toContain('격리됨')
    expect(drop?.textContent).toContain('minimax-m3')
    expect(drop?.textContent).toContain('Timeout')
    expect(drop?.textContent).toContain('meta는 살아남은 종합만으로 reconcile')
  })

  it('expands judge-of-judges 1차 심판 into per-node cards with decision, summary, derived counts, and isolation', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-joj-cards',
        title: 'Fusion deliberation (run joj-cards): answer',
        meta: {
          source: 'fusion',
          run_id: 'joj-cards',
          question: 'round.ml redesign?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'a' }],
          judge: {
            status: 'synthesized',
            decision: 'answer',
            resolved_answer: 'reconciled answer',
            // meta consensus/contradictions reference the 1차 심판 identities —
            // the single source of truth the cards derive 합의/상충 counts from.
            consensus: [{ text: 'patch first', models: ['skeptic', 'pragmatist'] }],
            contradictions: [
              { topic: 'roadmap', positions: [['pragmatist', 'adopt'], ['literalist', 'defer']] },
            ],
          },
          judges: [
            {
              role: 'first',
              identity: 'skeptic',
              decision: 'recommend — patch first',
              resolved_answer: 'Skeptic: patch the isolation first, rewrite is unjustified.',
              input_tokens: 3010,
              output_tokens: 980,
            },
            {
              role: 'first',
              identity: 'literalist',
              decision: 'insufficient — missing: benchmarks',
              resolved_answer: 'Literalist: no quantitative basis, benchmark first.',
              input_tokens: 3010,
              output_tokens: 720,
            },
            { role: 'first', identity: 'domain', status: 'failed', error: 'Timeout' },
            { role: 'meta', identity: 'meta', input_tokens: 4120, output_tokens: 1510 },
          ],
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const grid = container.querySelector('[data-testid="fusion-first-judges"]')
    expect(grid).not.toBeNull()
    // 3 first-tier nodes become cards (meta is not a card); the failed one is isolated
    expect(grid?.querySelectorAll('.fus-jnode')).toHaveLength(3)

    // Free-form wire decisions are not substring-promoted into semantic badges.
    // They stay raw/neutral so protocol drift remains visible.
    expect(grid?.textContent).toContain('recommend — patch first')
    expect(grid?.textContent).toContain('insufficient — missing: benchmarks')
    expect(grid?.textContent).not.toContain('권고')
    expect(grid?.textContent).not.toContain('심의 무효')
    // resolved-answer gist as the card summary
    expect(grid?.textContent).toContain('Skeptic: patch the isolation first')

    // derived counts: skeptic is cited in 1 consensus claim, 0 contradictions;
    // literalist in 0 consensus, 1 contradiction (matched on identity).
    const skepticCard = Array.from(grid?.querySelectorAll('.fus-jnode') ?? []).find(card =>
      card.textContent?.includes('skeptic'),
    )
    expect(skepticCard?.textContent).toContain('합의 1')
    expect(skepticCard?.textContent).toContain('상충 0')
    const literalistCard = Array.from(grid?.querySelectorAll('.fus-jnode') ?? []).find(card =>
      card.textContent?.includes('literalist'),
    )
    expect(literalistCard?.textContent).toContain('합의 0')
    expect(literalistCard?.textContent).toContain('상충 1')

    // the failed 1차 심판 is an isolation card, not dropped
    const isolated = grid?.querySelector('.fus-jnode.failed')
    expect(isolated?.textContent).toContain('domain')
    expect(isolated?.textContent).toContain('Timeout')
    expect(isolated?.textContent).toContain('격리됨')
  })

  it('renders no 1차 심판 card grid for a non-JoJ run', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-simple-nocards',
        title: 'Fusion deliberation (run simple-1): answer',
        meta: {
          source: 'fusion',
          run_id: 'simple-1',
          question: 'simple?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'a' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'simple answer' },
          judges: [{ role: 'single', identity: 'single', input_tokens: 100, output_tokens: 10 }],
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    expect(container.querySelector('[data-testid="fusion-first-judges"]')).toBeNull()
  })

  it('branches the pipeline strip for a refine run', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-refine',
        title: 'Fusion deliberation (run refine-1): answer',
        meta: {
          source: 'fusion',
          run_id: 'refine-1',
          question: 'Refine path?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'a' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'refined answer' },
          judges: [
            { role: 'single', identity: 'single', input_tokens: 100, output_tokens: 10 },
            { role: 'refine', identity: 'refine', input_tokens: 120, output_tokens: 20 },
          ],
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const pipe = container.querySelector('[data-testid="fusion-pipe"]')
    expect(pipe?.textContent).toContain('심판')
    expect(pipe?.querySelector('.fus-pipe-node.meta')?.textContent).toContain('재검토')
    // no locally-pinned topology chip/tag vocabulary
    expect(container.querySelector('.fus-topo')).toBeNull()
    expect(container.querySelector('.fus-row-topo')).toBeNull()
  })

  it('renders a legacy (pre-judges) post as a single judge node with no meta or topology vocabulary', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-legacy',
        title: 'Fusion deliberation (run legacy-1): answer',
        meta: {
          source: 'fusion',
          run_id: 'legacy-1',
          question: 'Legacy?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'a' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'legacy answer' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    // no invented topology vocabulary anywhere, and no meta reconcile surface
    expect(container.querySelector('.fus-topo')).toBeNull()
    expect(container.querySelector('.fus-row-topo')).toBeNull()
    expect(container.querySelector('.fus-meta-drop')).toBeNull()
    // single judge node keeps its decision label (no meta node)
    const pipe = container.querySelector('[data-testid="fusion-pipe"]')
    expect(pipe?.querySelector('.fus-pipe-node.meta')).toBeNull()
  })

  it('clamps a long resolved_answer with a reveal toggle', async () => {
    const longAnswer = `${'결론은 카나리 우선 배포입니다. '.repeat(31)}`
    expect(longAnswer.length).toBeGreaterThan(540)
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-long',
        title: 'Fusion deliberation (run long-1): answer',
        meta: {
          source: 'fusion',
          run_id: 'long-1',
          question: 'Which path?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'a' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: longAnswer },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const rich = container.querySelector('.fus-resolved-body .fus-rich')
    expect(rich?.classList.contains('clamp')).toBe(true)
    const more = container.querySelector<HTMLButtonElement>('.fus-rich-more')
    expect(more).not.toBeNull()
    expect(more?.textContent).toContain('전문 펼치기')
    more?.click()
    // preact schedules the useState re-render on a microtask; flush it before asserting.
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(container.querySelector('.fus-resolved-body .fus-rich')?.classList.contains('clamp')).toBe(false)
    expect(container.querySelector('.fus-rich-more')?.textContent).toContain('접기')
  })

  it('does not clamp a short resolved_answer', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-short',
        title: 'Fusion deliberation (run short-1): answer',
        meta: {
          source: 'fusion',
          run_id: 'short-1',
          question: 'Which path?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'a' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Ship canary first.' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    expect(container.querySelector('.fus-resolved-body .fus-rich')?.classList.contains('clamp')).toBe(false)
    expect(container.querySelector('.fus-rich-more')).toBeNull()
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
    expect(container.textContent).toContain('아직 기록된 보드 심의가 없습니다')
    expect(container.textContent).toContain('/api/v1/dashboard/fusion-runs')
  })

  it('surfaces board-sink fetch failure instead of claiming an empty sink', () => {
    fusionBoardError.value = 'HTTP 502 board sink unavailable'

    render(html`<${FusionSurface} />`, container)

    const error = container.querySelector('[data-testid="fusion-board-error"]')
    expect(error).not.toBeNull()
    expect(error?.getAttribute('data-board-source')).toBe('/api/v1/dashboard/board')
    expect(error?.getAttribute('data-board-sort')).toBe('recent')
    expect(error?.getAttribute('data-board-limit')).toBe('500')
    expect(error?.textContent).toContain('Board sink load failed')
    expect(error?.textContent).toContain('HTTP 502 board sink unavailable')
    const empty = container.querySelector('[data-testid="fusion-empty"]')
    expect(empty?.textContent).toContain('보드 심의 기록을 확인하지 못했습니다')
    expect(empty?.textContent).toContain('/api/v1/dashboard/board?sort_by=recent&limit=500')
    expect(empty?.textContent).not.toContain('아직 기록된 보드 심의가 없습니다')
  })

  it('keeps cached board-sink detail visible while showing a refresh failure', () => {
    fusionBoardError.value = 'network offline'
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-fus-cached',
        title: 'Fusion deliberation (run fus-cached): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-cached',
          question: 'Cached run?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'Use cached evidence.' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Cached answer.' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    expect(container.querySelector('[data-testid="fusion-board-error"]')?.textContent).toContain('network offline')
    const detail = container.querySelector('[data-testid="fusion-detail"]')
    expect(detail?.textContent).toContain('fus-cached')
    expect(detail?.textContent).toContain('Cached answer')
    expect(container.querySelector('[data-testid="fusion-empty"]')).toBeNull()
  })

  it('merges a registry-only running run into the master list instead of a separate top panel', () => {
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

    // Registry-only run now lives in the sidebar master list (2-pane layout),
    // not the removed top "Run status" panel.
    expect(container.querySelector('[data-testid="fusion-run-status-card"]')).toBeNull()
    const row = container.querySelector('[data-testid="fusion-registry-row"]')
    expect(row?.textContent).toContain('fus-running')
    // A real run exists, so there is no board-sink empty placeholder — the
    // registry run is selected by default and shows its own detail.
    expect(container.querySelector('[data-testid="fusion-empty"]')).toBeNull()
    expect(container.querySelector('[data-testid="fusion-registry-detail"]')?.textContent).toContain('fus-running')
    expect(container.textContent).toContain('보드 런')
    expect(container.textContent).toContain('레지스트리')
    // The running count now surfaces as the sidebar live badge, not the removed panel.
    expect(container.textContent).toContain('1 진행')
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

  it('does not derive judge run status from status substrings', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-fus-judge-status-substring',
        title: 'Fusion deliberation (run fus-judge-status-substring): pending',
        meta: {
          source: 'fusion',
          run_id: 'fus-judge-status-substring',
          question: 'Judge status edge cases?',
          panel: [{ model: 'm1', status: 'answered', answer: 'Panel answer.' }],
          judge: { status: 'failover' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const detail = container.querySelector('[data-testid="fusion-detail"]')
    expect(detail?.textContent).toContain('running')
    expect(container.querySelector('.fus-rdot.run')).not.toBeNull()
    expect(container.querySelector('.fus-rdot.deny')).toBeNull()
  })

  it('renders the panel reason_code as a category chip on a failed panel card', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-fus-reason-code',
        title: 'Fusion deliberation (run fus-reason-code): mixed',
        meta: {
          source: 'fusion',
          run_id: 'fus-reason-code',
          question: 'Reason code?',
          panel: [
            { model: 'gpt-5', status: 'answered', answer: 'ok' },
            {
              model: 'claude',
              status: 'failed',
              reason_code: 'provider_error',
              reason_detail: 'quota exceeded',
            },
          ],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'done' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const failedCard = container.querySelector('.fus-panel-card.failed')
    const code = failedCard?.querySelector('.fus-pcode')
    expect(code?.textContent).toBe('provider_error')
    // the human detail still shows in the state chip; the answered card has no code
    expect(failedCard?.textContent).toContain('quota exceeded')
    const answeredCard = container.querySelector('.fus-panel-card.answered')
    expect(answeredCard?.querySelector('.fus-pcode')).toBeNull()
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

  const minimalFusionPost = (runId: string, createdAt: string, updatedAt: string) =>
    boardPost({
      id: `post-${runId}`,
      title: `Fusion deliberation (run ${runId})`,
      created_at: createdAt,
      updated_at: updatedAt,
      meta: {
        source: 'fusion',
        run_id: runId,
        question: `Question for ${runId}?`,
        panel: [],
        judge: { status: 'synthesized', decision: 'answer', synthesis: 's', resolved_answer: 'r' },
      },
    })

  it('orders the master list by creation time, not board update time (#34)', () => {
    // fus-old was CREATED first but its board post was touched later;
    // fus-new must still render above it.
    fusionBoardPosts.value = [
      minimalFusionPost('fus-old', '2026-06-19T01:00:00Z', '2026-06-19T09:00:00Z'),
      minimalFusionPost('fus-new', '2026-06-19T05:00:00Z', '2026-06-19T05:01:00Z'),
    ]

    render(html`<${FusionSurface} />`, container)

    const ids = Array.from(container.querySelectorAll('.fus-run-row .fus-run-id')).map(
      el => el.textContent,
    )
    expect(ids).toEqual(['fus-new', 'fus-old'])
  })

  it('pages the master list and reveals more rows on demand (#34)', async () => {
    const posts = []
    for (let i = 0; i < 33; i += 1) {
      const minute = String(i).padStart(2, '0')
      posts.push(
        minimalFusionPost(
          `fus-${minute}`,
          `2026-06-19T01:${minute}:00Z`,
          `2026-06-19T01:${minute}:30Z`,
        ),
      )
    }
    fusionBoardPosts.value = posts

    render(html`<${FusionSurface} />`, container)

    expect(container.querySelectorAll('.fus-run-row').length).toBe(30)
    const more = container.querySelector<HTMLButtonElement>('[data-testid="fusion-list-more"]')
    expect(more).not.toBeNull()
    expect(more?.textContent).toContain('3개 남음')

    more?.click()

    await waitFor(() => {
      expect(container.querySelectorAll('.fus-run-row').length).toBe(33)
    })
    expect(container.querySelector('[data-testid="fusion-list-more"]')).toBeNull()
  })

  it('더 보기 grows from the auto-extended deep-link count, not the latch (#34 P2)', async () => {
    // 70 runs; deep-link selects sorted index 65 (i=4 in creation order), so
    // the list auto-extends to 66 rows while the page latch stays at 30.
    // Growing the latch alone (30 -> 60 < 66) made the first clicks no-ops;
    // one click must now reveal the remaining rows.
    const posts = []
    for (let i = 0; i < 70; i += 1) {
      const hour = String(1 + Math.floor(i / 60)).padStart(2, '0')
      const minute = String(i % 60).padStart(2, '0')
      posts.push(
        minimalFusionPost(
          `fus-${String(i).padStart(3, '0')}`,
          `2026-06-19T${hour}:${minute}:00Z`,
          `2026-06-19T${hour}:${minute}:30Z`,
        ),
      )
    }
    fusionBoardPosts.value = posts
    route.value = { tab: 'fusion', params: { run_id: 'fus-004' }, postId: null }

    render(html`<${FusionSurface} />`, container)

    expect(container.querySelectorAll('.fus-run-row').length).toBe(66)
    const more = container.querySelector<HTMLButtonElement>('[data-testid="fusion-list-more"]')
    expect(more?.textContent).toContain('4개 남음')

    more?.click()

    await waitFor(() => {
      expect(container.querySelectorAll('.fus-run-row').length).toBe(70)
    })
    expect(container.querySelector('[data-testid="fusion-list-more"]')).toBeNull()
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

  it('surfaces failure_code and elapsed timing on a failed node, marking a timeout', () => {
    const failing: FusionJudgeNode[] = [
      {
        role: 'meta',
        identity: 'o1',
        failed: true,
        error: 'judge timed out',
        failureCode: 'timeout',
        elapsedS: 30.2,
        timedOut: true,
        inputTokens: 800,
        outputTokens: 0,
      },
    ]
    render(html`<${FusionJudgesStrip} nodes=${failing} />`, container)
    const row = container.querySelector('[data-failed="true"]')
    expect(row?.querySelector('.fus-jn-code')?.textContent).toBe('timeout')
    const time = row?.querySelector('.fus-jn-time')
    expect(time?.textContent).toBe('30.2s')
    // timed_out is consumed, not just the code — the elapsed chip is marked
    expect(time?.classList.contains('timeout')).toBe(true)
  })

  it('shows elapsed without the timeout mark for a non-timeout failure', () => {
    const failing: FusionJudgeNode[] = [
      {
        role: 'single',
        identity: 'single',
        failed: true,
        error: 'could not parse structured output',
        failureCode: 'parse_error',
        elapsedS: 2.4,
        timedOut: false,
      },
    ]
    render(html`<${FusionJudgesStrip} nodes=${failing} />`, container)
    const time = container.querySelector('[data-failed="true"] .fus-jn-time')
    expect(time?.textContent).toBe('2.4s')
    expect(time?.classList.contains('timeout')).toBe(false)
    expect(container.querySelector('.fus-jn-code')?.textContent).toBe('parse_error')
  })
})
