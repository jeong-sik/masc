import { html } from 'htm/preact'
import { h, render } from 'preact'
import { act, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { BoardPost } from '../../types'
import type { FusionRunRecord } from '../../api/dashboard-fusion'
import { route } from '../../router'
import {
  forgetFusionEvidenceRequests,
  fusionBoardError,
  fusionBoardLoading,
  fusionBoardPosts,
  fusionRuns,
  fusionRunsLoading,
} from '../../store'
import { FusionSurface } from './fusion-surface'

const api = vi.hoisted(() => ({
  evidence: vi.fn<(runId: string) => Promise<BoardPost | null>>(),
  board: vi.fn(),
  runs: vi.fn(),
}))
vi.mock('../../api/board', async importOriginal => ({
  ...await importOriginal<typeof import('../../api/board')>(),
  fetchFusionRunEvidencePost: api.evidence,
}))
vi.mock('../../api/dashboard-execution', async importOriginal => ({
  ...await importOriginal<typeof import('../../api/dashboard-execution')>(),
  fetchDashboardMemory: api.board,
}))
vi.mock('../../api/dashboard-fusion', async importOriginal => ({
  ...await importOriginal<typeof import('../../api/dashboard-fusion')>(),
  fetchFusionRuns: api.runs,
}))
vi.mock('../common/markdown', () => ({
  Markdown: (props: { text: string }) => h('div', {}, props.text),
}))

const registryRun: FusionRunRecord = {
  runId: 'old-run', keeper: 'fusion-keeper', preset: 'review', topology: 'simple',
  startedAt: 1_780_000_000, status: 'completed',
}
function evidence(answer: string): BoardPost {
  return {
    id: 'old-post', author: 'fusion-keeper', post_kind: 'automation', pinned: false,
    title: 'Archived deliberation', body: answer,
    origin: { source: 'fusion', fusion_run_id: 'old-run' },
    meta: {
      question: 'Archived question',
      panel: [{ model: 'fixture', status: 'answered', answer }],
      judge: { status: 'synthesized', decision: 'answer', resolved_answer: answer },
    },
    tags: [], votes: 0, comment_count: 0,
    created_at: '2026-06-19T01:00:00Z', updated_at: '2026-06-19T01:00:00Z',
  }
}

describe('Fusion exact evidence through the rendered surface', () => {
  let container: HTMLDivElement
  beforeEach(() => {
    vi.clearAllMocks()
    forgetFusionEvidenceRequests()
    container = document.createElement('div')
    document.body.appendChild(container)
    route.value = { tab: 'fusion', params: {}, postId: null }
    fusionBoardPosts.value = []
    fusionBoardError.value = null
    fusionBoardLoading.value = false
    fusionRuns.value = [registryRun]
    fusionRunsLoading.value = false
    api.board.mockResolvedValue({ posts: [] }) // The recent window never has old-post.
    api.runs.mockResolvedValue({ runs: [registryRun], count: 1, generatedAt: null })
  })
  afterEach(() => {
    render(null, container)
    container.remove()
    forgetFusionEvidenceRequests()
    fusionBoardPosts.value = []
    fusionRuns.value = []
    route.value = { tab: 'overview', params: {}, postId: null }
  })

  async function refreshFromSurface() {
    const refresh = container.querySelector<HTMLButtonElement>('.fus-refresh')
    expect(refresh).not.toBeNull()
    await act(() => refresh?.click())
    await waitFor(() => expect(api.board).toHaveBeenCalledTimes(1))
  }

  it('loads the default registry selection even without a routed run id', async () => {
    api.evidence.mockResolvedValue(evidence('Recovered default evidence'))
    render(html`<${FusionSurface} />`, container)

    await waitFor(() => expect(container.textContent).toContain('Recovered default evidence'))
    expect(api.evidence).toHaveBeenCalledExactlyOnceWith('old-run')
    expect(route.value.params).toEqual({})
    await act(() => render(html`<${FusionSurface} />`, container))
    expect(api.evidence).toHaveBeenCalledTimes(1)
  })

  it.each(['absent', 'failed'] as const)('retries a %s exact read on refresh while selection stays unchanged', async outcome => {
    route.value = { tab: 'fusion', params: { run_id: 'old-run' }, postId: null }
    if (outcome === 'absent') api.evidence.mockResolvedValueOnce(null)
    else api.evidence.mockRejectedValueOnce(new Error('temporary upstream failure'))
    api.evidence.mockResolvedValueOnce(evidence('Recovered after refresh'))
    render(html`<${FusionSurface} />`, container)
    await waitFor(() => expect(api.evidence).toHaveBeenCalledTimes(1))
    expect(container.querySelector('[data-testid="fusion-registry-detail"]')).not.toBeNull()

    await refreshFromSurface()

    await waitFor(() => expect(container.textContent).toContain('Recovered after refresh'))
    expect(api.evidence).toHaveBeenCalledTimes(2)
    expect(route.value.params).toEqual({ run_id: 'old-run' })
    expect(api.board).toHaveBeenCalledWith('recent', { limit: 500, offset: 0 })
  })

  it('does not let a pre-refresh response replace the new exact evidence', async () => {
    let settleOld!: (post: BoardPost) => void
    const pending = new Promise<BoardPost>(resolve => { settleOld = resolve })
    api.evidence.mockReturnValueOnce(pending)
    api.evidence.mockResolvedValueOnce(evidence('Current exact evidence'))
    render(html`<${FusionSurface} />`, container)
    await waitFor(() => expect(api.evidence).toHaveBeenCalledTimes(1))

    await refreshFromSurface()
    await waitFor(() => expect(container.textContent).toContain('Current exact evidence'))
    await act(async () => { settleOld(evidence('Superseded exact evidence')); await pending })

    expect(container.textContent).toContain('Current exact evidence')
    expect(container.textContent).not.toContain('Superseded exact evidence')
    expect(api.evidence).toHaveBeenCalledTimes(2)
  })
})
