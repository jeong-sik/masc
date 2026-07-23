import { cleanup, render, screen } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it } from 'vitest'
import '@testing-library/jest-dom'

import { keeperStatusDetails } from '../keeper-state'
import { PlaygroundReposPanel } from './keeper-detail-comms'

afterEach(() => {
  cleanup()
  keeperStatusDetails.value = {}
})

describe('PlaygroundReposPanel', () => {
  it('renders raw filesystem entries without Git enrichment', () => {
    keeperStatusDetails.value = {
      sangsu: {
        name: 'sangsu',
        history: [],
        rawText: '',
        loadedAt: '2026-07-13T00:00:00Z',
        rawStatus: {
          execution_context: {
            playground_repos: [
              {
                name: 'plain-directory',
                path: 'repos/plain-directory',
                source: 'filesystem',
              },
            ],
          },
        },
      },
    }

    render(html`<${PlaygroundReposPanel} keeperName="sangsu" />`)

    expect(screen.getByText('plain-directory')).toBeInTheDocument()
    expect(screen.getByText('repos/plain-directory')).toBeInTheDocument()
    expect(screen.getByText('filesystem')).toBeInTheDocument()
    expect(screen.getByText('branch unavailable')).toBeInTheDocument()
    expect(screen.getByText('Git metadata unavailable')).toBeInTheDocument()
  })

  it('keeps available Git observations while treating them as optional', () => {
    keeperStatusDetails.value = {
      sangsu: {
        name: 'sangsu',
        history: [],
        rawText: '',
        loadedAt: '2026-07-13T00:00:00Z',
        rawStatus: {
          execution_context: {
            playground_repos: [
              {
                name: 'enriched-directory',
                branch: 'main',
                latest_commit: 'abc123',
                shallow: true,
                last_action: 'synced',
              },
            ],
          },
        },
      },
    }

    render(html`<${PlaygroundReposPanel} keeperName="sangsu" />`)

    expect(screen.getByText('main')).toBeInTheDocument()
    expect(screen.getByText('abc123')).toBeInTheDocument()
    expect(screen.getByText('shallow')).toBeInTheDocument()
    expect(screen.getByText('synced')).toBeInTheDocument()
  })
})
