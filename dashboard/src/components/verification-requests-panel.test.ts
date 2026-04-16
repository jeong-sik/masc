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
  Card: ({ title, children }: any) => html`
    <div data-testid="card"><h3>${title}</h3>${children}</div>
  `,
}))

vi.mock('./common/empty-state', () => ({
  EmptyState: ({ children }: any) => html`
    <div data-testid="empty-state">${children}</div>
  `,
}))

vi.mock('./common/feedback-state', () => ({
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

import { VerificationRequestsPanel } from './verification-requests-panel'

function makeRequest(overrides: Partial<VerificationRequest> = {}): VerificationRequest {
  return {
    request_id: 'req-001',
    task_id: 'task-001',
    keeper: null,
    status: 'pending',
    created_at: new Date().toISOString(),
    submitted_by: 'agent-a',
    approved_by: null,
    completion_contract: [],
    required_evidence: [],
    verdict: null,
    verdict_reason: '',
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

  it('renders FilterChips for all statuses with counts', () => {
    setData([makeRequest()])
    render(html`<${VerificationRequestsPanel} />`)
    expect(screen.getByTestId('filter-chip-all')).toBeTruthy()
    expect(screen.getByTestId('filter-chip-pending')).toBeTruthy()
    expect(screen.getByTestId('filter-chip-approved')).toBeTruthy()
    expect(screen.getByTestId('filter-chip-rejected')).toBeTruthy()
    expect(screen.getByTestId('filter-chip-timed_out')).toBeTruthy()
  })

  it('shows total count in all filter mode', () => {
    setData([makeRequest(), makeRequest({ request_id: 'req-002', status: 'approved' })])
    render(html`<${VerificationRequestsPanel} />`)
    expect(screen.getByText('총 2건')).toBeTruthy()
  })

  it('filters by pending status', () => {
    const pending = makeRequest({ request_id: 'req-p', status: 'pending' })
    const approved = makeRequest({ request_id: 'req-a', status: 'approved' })
    setData([pending, approved])
    render(html`<${VerificationRequestsPanel} />`)

    fireEvent.click(screen.getByTestId('filter-chip-pending'))
    const card = screen.getByTestId('card')
    expect(card.innerHTML).toContain('req-p')
    expect(card.innerHTML).not.toContain('req-a')
    expect(screen.getByText('1 / 2건')).toBeTruthy()
  })

  it('filters by approved status', () => {
    const pending = makeRequest({ request_id: 'req-p', status: 'pending' })
    const approved = makeRequest({ request_id: 'req-a', status: 'approved' })
    setData([pending, approved])
    render(html`<${VerificationRequestsPanel} />`)

    fireEvent.click(screen.getByTestId('filter-chip-approved'))
    const card = screen.getByTestId('card')
    expect(card.innerHTML).toContain('req-a')
    expect(card.innerHTML).not.toContain('req-p')
  })

  it('shows filter-specific empty state when no matches', () => {
    setData([makeRequest({ status: 'approved' })])
    render(html`<${VerificationRequestsPanel} />`)

    fireEvent.click(screen.getByTestId('filter-chip-rejected'))
    expect(screen.getByTestId('empty-state')).toBeTruthy()
  })

  it('shows error state', () => {
    mockState.value = { loading: false, error: 'Network error', data: null }
    render(html`<${VerificationRequestsPanel} />`)
    expect(screen.getByTestId('error-state')).toBeTruthy()
  })

  it('shows per-status counts in FilterChips', () => {
    const pending = makeRequest({ request_id: 'req-p', status: 'pending' })
    const approved = makeRequest({ request_id: 'req-a', status: 'approved' })
    const rejected = makeRequest({ request_id: 'req-r', status: 'rejected' })
    setData([pending, approved, rejected])
    render(html`<${VerificationRequestsPanel} />`)

    const allChip = screen.getByTestId('filter-chip-all')
    const pendingChip = screen.getByTestId('filter-chip-pending')
    expect(allChip.textContent).toContain('3')
    expect(pendingChip.textContent).toContain('1')
  })

  it('filters by search query', async () => {
    const req1 = makeRequest({ request_id: 'req-alpha', task_id: 'task-001', submitted_by: 'keeper-x' })
    const req2 = makeRequest({ request_id: 'req-beta', task_id: 'task-002', submitted_by: 'keeper-y' })
    setData([req1, req2])
    render(html`<${VerificationRequestsPanel} />`)

    // Reset status filter from previous test (module-scope signal)
    fireEvent.click(screen.getByTestId('filter-chip-all'))

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

    fireEvent.click(screen.getByTestId('filter-chip-all'))

    const searchInput = screen.getByTestId('search-input')
    fireEvent.input(searchInput, { target: { value: 'nonexistent' } })
    await waitFor(() => {
      expect(screen.getByTestId('empty-state')).toBeTruthy()
    })
  })
})
