import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { cleanup, render, screen, fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type {
  VerificationRequest,
  VerificationRequestsResponse,
} from '../api/dashboard'

// ── Mock async-state ──────────────────────────────────

const mockState = signal({
  loading: false,
  error: null as string | null,
  data: null as VerificationRequestsResponse | null,
})

vi.mock('../lib/async-state', () => ({
  createManagedAsyncResource: () => ({
    state: mockState,
    load: vi.fn(),
    cancel: vi.fn(),
  }),
}))

// ── Mock API ──────────────────────────────────────────

vi.mock('../api/dashboard', () => ({
  fetchVerificationRequests: vi.fn(),
}))

// ── Mock UI primitives (real Preact components) ───────

vi.mock('./common/card', () => ({
  SectionCard: ({ label, children }: any) => html`
    <div data-testid="card"><h3>${label}</h3>${children}</div>
  `,
}))

vi.mock('./common/feedback-state', () => ({
  EmptyState: ({ children }: any) => html`
    <div data-testid="empty-state">${children}</div>
  `,
  ErrorState: ({ message }: any) => html`
    <div data-testid="error-state">${message}</div>
  `,
  LoadingState: ({ children }: any) => html`
    <div data-testid="loading-state">${children}</div>
  `,
}))

vi.mock('./common/status-chip', () => ({
  StatusChip: ({ tone, children }: any) => html`
    <span data-testid="status-chip" data-tone=${tone}>${children}</span>
  `,
}))

vi.mock('./common/filter-chips', () => ({
  FilterChips: ({ chips, active }: any) => html`
    <div data-testid="filter-chips">
      ${chips.map((chip: any) => html`
        <button
          key=${chip.key}
          data-testid="filter-chip-${chip.key}"
          data-active=${active?.value === chip.key}
          onClick=${() => { if (active) active.value = chip.key }}
        >${chip.label}${chip.count != null ? ` (${chip.count})` : ''}</button>
      `)}
    </div>
  `,
}))

vi.mock('./common/input', () => ({
  TextInput: ({ value, onInput, placeholder, ariaLabel }: any) => html`
    <input
      data-testid="search-input"
      value=${value}
      placeholder=${placeholder}
      aria-label=${ariaLabel}
      onInput=${onInput}
    />
  `,
}))

// ── Import after mocks ────────────────────────────────

import {
  __resetVerificationRequestsPanelForTest,
  VerificationRequestsPanel,
} from './verification-requests-panel'

function makeRequest(overrides: Partial<VerificationRequest> = {}): VerificationRequest {
  return {
    request_id: 'req-001',
    task_id: 'task-001',
    task_title: '',
    created_at: new Date().toISOString(),
    submitted_by: 'agent-a',
    completion_contract: [],
    required_artifacts: [],
    submitted_evidence: [],
    evidence_projection_error: null,
    ...overrides,
  }
}

function setData(requests: VerificationRequest[]) {
  mockState.value = {
    loading: false,
    error: null,
    data: {
      updated_at: new Date().toISOString(),
      total: requests.length,
      requests,
    },
  }
}

describe('VerificationRequestsPanel', () => {
  beforeEach(() => {
    mockState.value = { loading: false, error: null, data: null }
    __resetVerificationRequestsPanelForTest()
  })
  afterEach(() => cleanup())

  it('shows loading state when no data and loading', () => {
    mockState.value = { loading: true, error: null, data: null }
    render(html`<${VerificationRequestsPanel} />`)
    expect(screen.getByTestId('loading-state')).toBeTruthy()
  })

  it('shows empty state when no requests exist', () => {
    setData([])
    render(html`<${VerificationRequestsPanel} />`)
    expect(screen.getByTestId('empty-state')).toBeTruthy()
  })


  it('marks the table and rows with v2 workspace classes', () => {
    setData([makeRequest()])
    const { container } = render(html`<${VerificationRequestsPanel} />`)
    expect(container.querySelector('.v2-workspace-surface')).not.toBeNull()
    expect(container.querySelector('.v2-workspace-table')).not.toBeNull()
    expect(container.querySelector('.v2-workspace-row')).not.toBeNull()
  })

  it('shows total count in all filter mode', () => {
    setData([makeRequest(), makeRequest({ request_id: 'req-002' })])
    render(html`<${VerificationRequestsPanel} />`)
    expect(screen.getByText('총 2건')).toBeTruthy()
  })




  it('shows error state', () => {
    mockState.value = { loading: false, error: 'Network error', data: null }
    render(html`<${VerificationRequestsPanel} />`)
    expect(screen.getByTestId('error-state')).toBeTruthy()
  })


  it('filters by search query', async () => {
    const req1 = makeRequest({ request_id: 'req-alpha', task_id: 'task-001', submitted_by: 'keeper-x' })
    const req2 = makeRequest({ request_id: 'req-beta', task_id: 'task-002', submitted_by: 'keeper-y' })
    setData([req1, req2])
    render(html`<${VerificationRequestsPanel} />`)

    const searchInput = screen.getByTestId('search-input')
    fireEvent.input(searchInput, { target: { value: 'alpha' } })
    await waitFor(() => {
      const card = screen.getByTestId('card')
      expect(card.innerHTML).toContain('req-alpha')
      expect(card.innerHTML).not.toContain('req-beta')
    })
  })

  it('shows filter-specific empty state with search', async () => {
    setData([makeRequest({ request_id: 'req-001' })])
    render(html`<${VerificationRequestsPanel} />`)

    const searchInput = screen.getByTestId('search-input')
    fireEvent.input(searchInput, { target: { value: 'nonexistent' } })
    await waitFor(() => {
      const empty = screen.getByTestId('empty-state')
      expect(empty).toBeTruthy()
      expect(empty.textContent).toContain('필터 결과 없음')
      expect(empty.textContent).toContain('1 items')
    })
  })

  // The panel used to draw a Verification Summary and a Next Action here. Both
  // came from fields the producer set to the empty string as literals, so the
  // two blocks were guarded off on every request the server has ever sent and
  // this test was the only thing that ever filled them -- by writing the
  // values into its own fixture.
  it('is read-only, and shows the task title it does carry', async () => {
    setData([
      makeRequest({
        request_id: 'req-conflict',
        task_title: 'wire the approval gate',
      }),
    ])
    render(html`<${VerificationRequestsPanel} />`)

    expect(screen.queryByRole('columnheader', { name: '액션' })).toBeNull()
    expect(screen.queryByRole('button', { name: '승인' })).toBeNull()
    expect(screen.queryByRole('button', { name: '반려' })).toBeNull()

    fireEvent.click(screen.getByText('자세히'))
    await waitFor(() => {
      expect(screen.getByText('wire the approval gate')).toBeTruthy()
      expect(screen.queryByText('Verification Summary')).toBeNull()
      expect(screen.queryByText('Next Action')).toBeNull()
    })
  })

  it('renders required artifacts separately from submitted evidence', async () => {
    setData([
      makeRequest({
        required_artifacts: ['artifact://required-contract'],
        submitted_evidence: ['trace://submitted-runtime-proof'],
      }),
    ])
    render(html`<${VerificationRequestsPanel} />`)

    fireEvent.click(screen.getByText('자세히'))
    await waitFor(() => {
      expect(screen.getByText('Required Artifacts')).toBeTruthy()
      expect(screen.getByText('artifact://required-contract')).toBeTruthy()
      expect(screen.getByText('Submitted Evidence')).toBeTruthy()
      expect(screen.getByText('trace://submitted-runtime-proof')).toBeTruthy()
      expect(screen.queryByText('Required Evidence')).toBeNull()
    })
  })

  // The identity lines the store now projects are not opaque tokens: they carry
  // path separators, a note prefix, Korean text, and a parenthesised failure
  // reason. Each must survive rendering intact, and an unreadable artifact must
  // stay visible instead of being dropped from the list.
  it('renders projected snapshot identity lines verbatim', async () => {
    setData([
      makeRequest({
        submitted_evidence: [
          'artifact:repos/demo/services/request-form/src/lib/reportError.ts',
          'note:executor summary — 비동기 에러 핸들링 통일 완료',
          'artifact:repos/demo/gone.ml (unreadable: missing)',
          '(unreadable: invalid_reference)',
        ],
      }),
    ])
    render(html`<${VerificationRequestsPanel} />`)

    fireEvent.click(screen.getByText('자세히'))
    await waitFor(() => {
      expect(
        screen.getByText(
          'artifact:repos/demo/services/request-form/src/lib/reportError.ts',
        ),
      ).toBeTruthy()
      expect(
        screen.getByText('note:executor summary — 비동기 에러 핸들링 통일 완료'),
      ).toBeTruthy()
      expect(
        screen.getByText('artifact:repos/demo/gone.ml (unreadable: missing)'),
      ).toBeTruthy()
      expect(screen.getByText('(unreadable: invalid_reference)')).toBeTruthy()
    })
  })

  // Live store extremes: a 1083-char reference and 77 notes over 200 chars.
  // A path carries no spaces, so without break-words the row overflows sideways
  // rather than wrapping. Assert the wrap class rides on both evidence lists.
  it('wraps oversized identity lines instead of overflowing the row', async () => {
    const longPath = `artifact:repos/demo/${'segment/'.repeat(120)}file.ts`
    expect(longPath.length).toBeGreaterThan(900)
    expect(longPath).not.toContain(' ')
    setData([
      makeRequest({
        required_artifacts: [longPath],
        submitted_evidence: [longPath],
      }),
    ])
    render(html`<${VerificationRequestsPanel} />`)

    fireEvent.click(screen.getByText('자세히'))
    await waitFor(() => {
      const lists = document.querySelectorAll('ul.list-disc')
      expect(lists.length).toBe(2)
      for (const list of lists) {
        expect(list.classList.contains('break-words')).toBe(true)
      }
      expect(screen.getAllByText(longPath).length).toBe(2)
    })
  })

  it('renders missing and malformed evidence projection warnings', () => {
    setData([
      makeRequest({
        evidence_projection_error:
          'missing current-schema field "required_artifacts"; malformed current-schema field "submitted_evidence": expected an array of strings',
      }),
    ])
    render(html`<${VerificationRequestsPanel} />`)

    expect(screen.getByRole('alert').textContent).toContain(
      'missing current-schema field "required_artifacts"',
    )
    expect(screen.getByRole('alert').textContent).toContain(
      'malformed current-schema field "submitted_evidence"',
    )
  })
})

// ── filterVerificationRequests pure helper ─────────────
