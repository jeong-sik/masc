import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { cleanup, render, screen, fireEvent } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type {
  TlaSpecEntry,
  TlaSpecsResponse,
} from '../api/dashboard'

// ── Mock async-state ──────────────────────────────────

const mockState = signal({
  loading: false,
  error: null as string | null,
  data: null as TlaSpecsResponse | null,
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
  fetchTlaSpecs: vi.fn(),
}))

// ── Mock UI primitives ────────────────────────────────

vi.mock('./common/card', () => ({
  Card: ({ title, children }: any) => html`
    <div data-testid="card"><h3>${title}</h3>${children}</div>
  `,
}))

vi.mock('./common/empty-state', () => ({
  EmptyState: ({ message }: any) => html`
    <div data-testid="empty-state">${message}</div>
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
  StatusChip: ({ tone, label, children }: any) => html`
    <span data-testid="status-chip" data-tone=${tone}>${label ?? children}</span>
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
        >${chip.label} (${chip.count ?? ''})</button>
      `)}
    </div>
  `,
}))

vi.mock('./common/input', () => ({
  TextInput: ({ value, onInput, placeholder }: any) => html`
    <input
      data-testid="search-input"
      value=${value}
      placeholder=${placeholder}
      onInput=${onInput}
    />
  `,
}))

// ── Import after mocks ────────────────────────────────

import { VerificationSpecsPanel } from './verification-specs-panel'

function makeEntry(overrides: Partial<TlaSpecEntry> = {}): TlaSpecEntry {
  return {
    name: 'KeeperOAS.tla',
    path: 'spec/keeper/KeeperOAS.tla',
    category: 'boundary',
    has_clean_cfg: true,
    has_buggy_cfg: true,
    mtime_iso: '2026-04-15T12:00:00Z',
    ...overrides,
  }
}

function setData(entries: TlaSpecEntry[]) {
  mockState.value = {
    loading: false,
    error: null,
    data: {
      updated_at: '2026-04-16T00:00:00Z',
      specs_dir: '/specs',
      count: entries.length,
      entries,
    },
  }
}

describe('VerificationSpecsPanel', () => {
  beforeEach(() => {
    mockState.value = { loading: false, error: null, data: null }
  })
  afterEach(() => cleanup())

  it('shows loading state when no data and loading', () => {
    mockState.value = { loading: true, error: null, data: null }
    render(html`<${VerificationSpecsPanel} />`)
    expect(screen.getByTestId('loading-state')).toBeTruthy()
  })

  it('shows empty state when no specs exist', () => {
    setData([])
    render(html`<${VerificationSpecsPanel} />`)
    expect(screen.getByTestId('empty-state')).toBeTruthy()
  })

  it('renders spec table with entries', () => {
    setData([makeEntry()])
    render(html`<${VerificationSpecsPanel} />`)
    const card = screen.getByTestId('card')
    expect(card.innerHTML).toContain('KeeperOAS.tla')
  })

  it('renders filter chips with counts', () => {
    setData([
      makeEntry({ name: 'a.tla', category: 'boundary' }),
      makeEntry({ name: 'b.tla', category: 'bug-models' }),
      makeEntry({ name: 'c.tla', category: 'other' }),
    ])
    render(html`<${VerificationSpecsPanel} />`)
    expect(screen.getByTestId('filter-chips')).toBeTruthy()
    const allChip = screen.getByTestId('filter-chip-all')
    expect(allChip.textContent).toContain('3')
  })

  it('shows total count in all filter mode', () => {
    setData([
      makeEntry({ name: 'a.tla' }),
      makeEntry({ name: 'b.tla', category: 'bug-models' }),
    ])
    render(html`<${VerificationSpecsPanel} />`)
    expect(screen.getByText('총 2건')).toBeTruthy()
  })

  it('shows filtered count when filter is active', () => {
    setData([
      makeEntry({ name: 'a.tla', category: 'boundary' }),
      makeEntry({ name: 'b.tla', category: 'bug-models' }),
    ])
    render(html`<${VerificationSpecsPanel} />`)

    const bugChip = screen.getByTestId('filter-chip-bug-models')
    fireEvent.click(bugChip)
    expect(screen.getByText('1 / 2건')).toBeTruthy()
  })

  it('filters by category', () => {
    const boundary = makeEntry({ name: 'boundary-spec.tla', category: 'boundary' })
    const bugModel = makeEntry({ name: 'bug-spec.tla', category: 'bug-models' })
    setData([boundary, bugModel])
    render(html`<${VerificationSpecsPanel} />`)

    const bugChip = screen.getByTestId('filter-chip-bug-models')
    fireEvent.click(bugChip)
    const card = screen.getByTestId('card')
    expect(card.innerHTML).toContain('bug-spec.tla')
    expect(card.innerHTML).not.toContain('boundary-spec.tla')
  })

  it('shows filter-specific empty state when no matches', () => {
    setData([makeEntry({ category: 'boundary' })])
    render(html`<${VerificationSpecsPanel} />`)

    const bugChip = screen.getByTestId('filter-chip-bug-models')
    fireEvent.click(bugChip)
    expect(screen.getByTestId('empty-state')).toBeTruthy()
  })

  it('shows error state', () => {
    mockState.value = { loading: false, error: 'Network error', data: null }
    render(html`<${VerificationSpecsPanel} />`)
    expect(screen.getByTestId('error-state')).toBeTruthy()
  })
})
