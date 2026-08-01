import { cleanup, render, screen } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it } from 'vitest'
import '@testing-library/jest-dom'

import { keeperStatusDetails } from '../keeper-state'
import { RepositoryCheckoutsPanel } from './keeper-detail-comms'

afterEach(() => {
  cleanup()
  keeperStatusDetails.value = {}
})

describe('RepositoryCheckoutsPanel', () => {
  it('renders an explicit unavailable inspection', () => {
    keeperStatusDetails.value = {
      sangsu: {
        name: 'sangsu',
        history: [],
        rawText: '',
        loadedAt: '2026-07-13T00:00:00Z',
        rawStatus: {
          execution_context: {
            repository_checkouts: { entries: [{
              checkout_name: 'plain-directory', path: 'repos/plain-directory',
              branch: null, head: null, dirty: null, inspection_state: 'unavailable',
              catalog: { state: 'unregistered' }, freshness: { state: 'unavailable' },
            }] },
          },
        },
      },
    }

    render(html`<${RepositoryCheckoutsPanel} keeperName="sangsu" />`)

    expect(screen.getByText('plain-directory')).toBeInTheDocument()
    expect(screen.getByText('repos/plain-directory')).toBeInTheDocument()
    expect(screen.getAllByText('unavailable').length).toBeGreaterThan(0)
    expect(screen.getByText('branch unavailable')).toBeInTheDocument()
    expect(screen.getByText('Git metadata unavailable')).toBeInTheDocument()
  })

  it('renders checkout freshness and dirty state', () => {
    keeperStatusDetails.value = {
      sangsu: {
        name: 'sangsu',
        history: [],
        rawText: '',
        loadedAt: '2026-07-13T00:00:00Z',
        rawStatus: {
          execution_context: {
            repository_checkouts: { entries: [{
              checkout_name: 'enriched-directory', path: 'repos/enriched-directory',
              branch: 'main', head: 'abc123', dirty: true, inspection_state: 'available',
              catalog: { state: 'registered', repository_id: 'masc' },
              freshness: { state: 'behind', behind: 22, ahead: 0 },
            }] },
          },
        },
      },
    }

    render(html`<${RepositoryCheckoutsPanel} keeperName="sangsu" />`)

    expect(screen.getByText('main')).toBeInTheDocument()
    expect(screen.getByText('abc123')).toBeInTheDocument()
    expect(screen.getByText('dirty')).toBeInTheDocument()
    expect(screen.getByText('behind')).toBeInTheDocument()
    expect(screen.getByText('behind 22 · ahead 0')).toBeInTheDocument()
  })
})
