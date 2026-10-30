import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { cleanup, render } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { TlaSpecEntry, TlaSpecsResponse } from '../api/dashboard'

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

vi.mock('./tlc-results-panel', () => ({
  TlcResultsPanel: () => html`<div data-testid="tlc-results-panel" />`,
}))

import { VerificationSpecsPanel } from './verification-specs-panel'

function makeEntry(overrides: Partial<TlaSpecEntry> = {}): TlaSpecEntry {
  return {
    name: 'TestSpec',
    path: 'specs/TestSpec.tla',
    category: 'boundary',
    mtime_iso: '2026-06-15T00:00:00Z',
    has_clean_cfg: true,
    has_buggy_cfg: true,
    ...overrides,
  }
}

function setData(entries: TlaSpecEntry[]) {
  mockState.value = {
    loading: false,
    error: null,
    data: {
      count: entries.length,
      entries,
      specs_dir: '/specs',
      updated_at: '2026-06-15T00:00:00Z',
    },
  }
}

describe('VerificationSpecsPanel', () => {
  beforeEach(() => {
    mockState.value = { loading: false, error: null, data: null }
  })
  afterEach(() => cleanup())

  it('marks the surface, table and rows with v2 monitoring classes', () => {
    setData([makeEntry()])
    const { container } = render(html`<${VerificationSpecsPanel} />`)
    expect(container.querySelector('.v2-monitoring-surface')).not.toBeNull()
    expect(container.querySelector('.v2-monitoring-table')).not.toBeNull()
    expect(container.querySelector('.v2-monitoring-row')).not.toBeNull()
  })
})
