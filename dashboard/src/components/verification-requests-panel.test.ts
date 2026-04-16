import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { cleanup, render, screen, fireEvent } from '@testing-library/preact'
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

  it('renders filter buttons for all statuses', () => {
    setData([makeRequest()])
    render(html`<${VerificationRequestsPanel} />`)
    // Filter buttons always present; table content may duplicate labels
    expect(screen.getAllByText('전체').length).toBeGreaterThanOrEqual(1)
    expect(screen.getAllByText('검증 대기').length).toBeGreaterThanOrEqual(1)
    expect(screen.getAllByText('승인').length).toBeGreaterThanOrEqual(1)
    expect(screen.getAllByText('반려').length).toBeGreaterThanOrEqual(1)
    expect(screen.getAllByText('시간 초과').length).toBeGreaterThanOrEqual(1)
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

    // Filter button is the first element with "검증 대기" text
    const pendingButtons = screen.getAllByText('검증 대기')
    fireEvent.click(pendingButtons[0])
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

    const approvedButtons = screen.getAllByText('승인')
    fireEvent.click(approvedButtons[0])
    const card = screen.getByTestId('card')
    expect(card.innerHTML).toContain('req-a')
    expect(card.innerHTML).not.toContain('req-p')
  })

  it('shows filter-specific empty state when no matches', () => {
    setData([makeRequest({ status: 'approved' })])
    render(html`<${VerificationRequestsPanel} />`)

    const rejectedButtons = screen.getAllByText('반려')
    fireEvent.click(rejectedButtons[0])
    expect(screen.getByTestId('empty-state')).toBeTruthy()
  })

  it('shows error state', () => {
    mockState.value = { loading: false, error: 'Network error', data: null }
    render(html`<${VerificationRequestsPanel} />`)
    expect(screen.getByTestId('error-state')).toBeTruthy()
  })
})
