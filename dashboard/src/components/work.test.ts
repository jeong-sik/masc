import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { cleanup, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

const routeSignal = signal({
  tab: 'workspace',
  params: { section: 'board' },
  postId: null,
})

vi.mock('../router', () => ({
  get route() { return routeSignal },
}))

vi.mock('./board', () => ({
  BoardSurface: () => html`<div data-testid="board-surface">Board</div>`,
  SubBoardSurface: () => html`<div data-testid="sub-board-surface">Sub-Boards</div>`,
}))

vi.mock('./planning-panel', () => ({
  PlanningPanel: () => html`<div data-testid="planning-panel">Planning</div>`,
}))

vi.mock('./verification-requests-panel', () => ({
  VerificationRequestsPanel: () => html`<div data-testid="verification-panel">Verification</div>`,
}))

vi.mock('./repository-management', () => ({
  RepositoryManagement: () => html`<div data-testid="repository-panel">Repositories</div>`,
}))

import { Work } from './work'

describe('Work', () => {
  afterEach(() => cleanup())

  it('renders the SubBoard surface for the workspace sub-boards section', () => {
    routeSignal.value = {
      tab: 'workspace',
      params: { section: 'sub-boards' },
      postId: null,
    }

    render(html`<${Work} />`)

    expect(screen.getByTestId('sub-board-surface')).toBeTruthy()
    expect(screen.queryByTestId('board-surface')).toBeNull()
  })

  it('falls back to the board surface for unknown workspace sections', () => {
    routeSignal.value = {
      tab: 'workspace',
      params: { section: 'unknown' },
      postId: null,
    }

    render(html`<${Work} />`)

    expect(screen.getByTestId('board-surface')).toBeTruthy()
  })
})
