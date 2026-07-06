import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import {
  KeeperCatchupDigestCard,
  keeperCatchupDigestActivityCount,
  shouldShowKeeperCatchupDigest,
} from './keeper-catchup-digest-card'
import { runKeeperCatchupJudgment } from '../api/keeper'
import { navigate } from '../router'
import type { KeeperCatchupDigest } from '../api/schemas/keeper-catchup-digest'

vi.mock('../api/keeper', () => ({
  runKeeperCatchupJudgment: vi.fn(),
}))

vi.mock('../router', () => ({
  navigate: vi.fn(),
}))

const runKeeperCatchupJudgmentMock = vi.mocked(runKeeperCatchupJudgment)
const navigateMock = vi.mocked(navigate)

function makeDigest(overrides: Partial<KeeperCatchupDigest> = {}): KeeperCatchupDigest {
  return {
    keeper: 'idealist',
    since_unix: 1_777_000_000,
    generated_at_unix: 1_777_000_120,
    chat: {
      new_messages: 2,
      first_new_ts: 1_777_000_030,
      transport_failures: 0,
    },
    turns: {
      completed: 10,
      failed: 0,
      crashes: 0,
    },
    tasks: {
      claimed: 0,
      done: 0,
      released: 0,
      cancelled: 0,
      items: [],
    },
    board: {
      posted: 3,
      commented: 0,
      voted: 0,
    },
    lifecycle: {
      paused_now: false,
      pause_events: 0,
      resume_events: 0,
      items: [],
    },
    coverage: {
      chat: { lower_bound: false, causes: [] },
      turns: { lower_bound: false, causes: [] },
      tasks: { lower_bound: false, causes: [] },
      board: { lower_bound: false, causes: [] },
      lifecycle: { lower_bound: false, causes: [] },
    },
    read_errors: [],
    ...overrides,
  }
}

describe('KeeperCatchupDigestCard', () => {
  afterEach(() => {
    cleanup()
    vi.clearAllMocks()
  })

  it('summarizes the digest counts and remains visible above the minimum activity threshold', () => {
    const digest = makeDigest()

    expect(keeperCatchupDigestActivityCount(digest)).toBe(15)
    expect(shouldShowKeeperCatchupDigest(digest)).toBe(true)

    render(html`<${KeeperCatchupDigestCard} digest=${digest} />`)

    expect(screen.getByText('그 사이 활동')).toBeInTheDocument()
    expect(screen.getByText('이후 2개 메시지')).toBeInTheDocument()
    expect(screen.getByText('메시지 2')).toBeInTheDocument()
    expect(screen.getByText('턴 10회')).toBeInTheDocument()
    expect(screen.getByText('보드 3')).toBeInTheDocument()
    expect(screen.getByTestId('keeper-catchup-judge-run')).toHaveTextContent('판정 실행')
  })

  it('starts a manual catch-up judgment and links to the Fusion run', async () => {
    const digest = makeDigest()
    runKeeperCatchupJudgmentMock.mockResolvedValue({
      ok: true,
      status: 'fusion_started',
      runId: 'fus-manual-1',
      ownerKeeper: 'idealist',
      fusionRoute: '/#fusion?run_id=fus-manual-1',
      digest,
    })

    render(html`<${KeeperCatchupDigestCard} digest=${digest} />`)

    fireEvent.click(screen.getByTestId('keeper-catchup-judge-run'))

    await waitFor(() => {
      expect(runKeeperCatchupJudgmentMock).toHaveBeenCalledWith('idealist', 1_777_000_000)
    })
    const openButton = await screen.findByTestId('keeper-catchup-judge-open')
    expect(openButton).toHaveTextContent('결과 보기')

    fireEvent.click(openButton)

    expect(navigateMock).toHaveBeenCalledWith('fusion', { run_id: 'fus-manual-1' })
  })

  it('renders a failure inline when the judgment request fails', async () => {
    const digest = makeDigest()
    runKeeperCatchupJudgmentMock.mockRejectedValue(new Error('fusion disabled'))

    render(html`<${KeeperCatchupDigestCard} digest=${digest} />`)

    fireEvent.click(screen.getByTestId('keeper-catchup-judge-run'))

    expect(await screen.findByRole('alert')).toHaveTextContent('fusion disabled')
    expect(screen.queryByTestId('keeper-catchup-judge-open')).toBeNull()
  })
})
