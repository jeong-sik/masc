import { h } from 'preact'
import { cleanup, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import '@testing-library/jest-dom'
import { FusionBoardEvidence } from './fusion-evidence'

afterEach(() => cleanup())

// Build a fusion board post whose meta carries the RFC-0284 `judges` observation
// array. `judges === undefined` models an older post that predates the array.
function fusionPost(judges: unknown) {
  return {
    meta: {
      source: 'fusion',
      run_id: 'fus-1',
      question: 'q?',
      panel: [{ model: 'gpt-5', status: 'answered', answer: 'panel answer' }],
      judge: { status: 'synthesized', synthesis: '최종 종합' },
      judges,
    },
  } as Parameters<typeof FusionBoardEvidence>[0]['post']
}

describe('FusionBoardEvidence judge topology strip (RFC-0284 PR 2)', () => {
  it('renders the observed judge-node topology for a judge-of-judges run', () => {
    render(
      h(FusionBoardEvidence, {
        post: fusionPost([
          { role: 'first', identity: 'gpt-5', input_tokens: 400, output_tokens: 1200 },
          { role: 'first', identity: 'claude', status: 'failed', error: 'timeout' },
          { role: 'meta', identity: 'meta', input_tokens: 100, output_tokens: 300 },
        ]),
      }),
    )
    const strip = screen.getByTestId('fusion-board-judges')
    expect(strip).toBeInTheDocument()
    // shape classified from array shape alone (any `first` ⟹ judge-of-judges)
    expect(strip.textContent).toContain('심판의 심판')
    expect(strip.textContent).toContain('관측된 심판 노드 3개')
    // role badges
    expect(strip.textContent).toContain('1차')
    expect(strip.textContent).toContain('메타')
    // per-node combined token figures (live arithmetic: 400+1200, 100+300)
    expect(strip.textContent).toContain('1.6k tok')
    expect(strip.textContent).toContain('400 tok')
    // exactly the failed first-judge carries the failed marker
    expect(strip.querySelectorAll('[data-failed="true"]')).toHaveLength(1)
    expect(strip.querySelectorAll('[data-fusion-judge-node]')).toHaveLength(3)
    // identity is suppressed for the meta node (echoes its role) but kept for the
    // `first` node — assert BOTH directions, else disabling suppression survives:
    // the role badge renders '메타' (Korean) so the latin role-echo identity 'meta'
    // must be absent from the meta row's text, while the first node keeps 'gpt-5'.
    expect(strip.textContent).toContain('gpt-5')
    const metaNode = strip.querySelector('[data-role="meta"]')
    expect(metaNode?.textContent).not.toContain('meta')
    // the canonical singular judge synthesis block is unchanged / still present
    const root = screen.getByTestId('fusion-board-evidence')
    expect(root.querySelector('[data-fusion-judge]')).not.toBeNull()
  })

  it('renders an all-fail judge-of-judges run (N first, no meta) with every row failed', () => {
    render(
      h(FusionBoardEvidence, {
        post: fusionPost([
          { role: 'first', identity: 'gpt-5', status: 'failed', error: 'timeout' },
          { role: 'first', identity: 'claude', status: 'failed', error: 'refused' },
        ]),
      }),
    )
    const strip = screen.getByTestId('fusion-board-judges')
    // `first` is JoJ-exclusive on the backend, so an all-fail JoJ (no meta node)
    // still classifies as judge-of-judges, not refine — the exact shape that a
    // bare node-count classifier would misread.
    expect(strip.textContent).toContain('심판의 심판')
    expect(strip.querySelectorAll('[data-fusion-judge-node]')).toHaveLength(2)
    expect(strip.querySelectorAll('[data-failed="true"]')).toHaveLength(2)
  })

  it('classifies a refine run from shape', () => {
    render(
      h(FusionBoardEvidence, {
        post: fusionPost([
          { role: 'single', identity: 'single' },
          { role: 'refine', identity: 'refine' },
        ]),
      }),
    )
    expect(screen.getByTestId('fusion-board-judges').textContent).toContain('재검토')
  })

  it('omits the strip when the meta predates the judges array', () => {
    render(h(FusionBoardEvidence, { post: fusionPost(undefined) }))
    expect(screen.queryByTestId('fusion-board-judges')).toBeNull()
    // the evidence card itself still renders the canonical content
    expect(screen.getByTestId('fusion-board-evidence')).toBeInTheDocument()
    expect(screen.getByTestId('fusion-board-evidence').querySelector('[data-fusion-judge]')).not.toBeNull()
  })

  it('returns null for non-fusion meta', () => {
    const { container } = render(
      h(FusionBoardEvidence, { post: { meta: { foo: 'bar' } } as Parameters<typeof FusionBoardEvidence>[0]['post'] }),
    )
    expect(container.querySelector('[data-testid="fusion-board-evidence"]')).toBeNull()
  })
})

describe('FusionBoardEvidence failure attribution', () => {
  it('surfaces failure_code and elapsed timing on a failed judge node', () => {
    render(
      h(FusionBoardEvidence, {
        post: fusionPost([
          {
            role: 'meta',
            identity: 'o1',
            status: 'failed',
            error: 'judge timed out',
            failure_code: 'timeout',
            elapsed_s: 30.2,
            timed_out: true,
          },
        ]),
      }),
    )
    const failedRow = screen.getByTestId('fusion-board-judges').querySelector('[data-failed="true"]')
    expect(failedRow?.querySelector('[data-fusion-judge-code]')?.textContent).toBe('timeout')
    expect(failedRow?.textContent).toContain('30.2s')
  })

  it('renders the panel reason_code chip on a failed panel', () => {
    const post = {
      meta: {
        source: 'fusion',
        run_id: 'fus-1',
        question: 'q?',
        panel: [
          { model: 'gpt-5', status: 'answered', answer: 'panel answer' },
          {
            model: 'claude',
            status: 'failed',
            reason_code: 'provider_error',
            reason_detail: 'quota exceeded',
          },
        ],
        judge: { status: 'synthesized', synthesis: '최종 종합' },
      },
    } as Parameters<typeof FusionBoardEvidence>[0]['post']
    render(h(FusionBoardEvidence, { post }))
    const codes = screen.getAllByText('provider_error', { selector: '[data-fusion-panel-code]' })
    expect(codes).toHaveLength(1)
    expect(codes[0]?.getAttribute('title')).toBe('quota exceeded')
  })
})
