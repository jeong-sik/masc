import { h } from 'preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

import { route } from '../../router'
import { Cockpit } from './cockpit'

vi.mock('../world-visualizer', () => ({
  WorldVisualizer: () => h('div', { 'data-testid': 'world-visualizer' }, 'World visualizer'),
}))

describe('Cockpit command map', () => {
  beforeEach(() => {
    window.location.hash = '#cockpit'
    route.value = { tab: 'cockpit', params: {}, postId: null }
  })

  afterEach(() => {
    cleanup()
  })

  it('renders one route section per cockpit plane', () => {
    render(h(Cockpit, null))

    expect(screen.getByTestId('cockpit-command-map')).toBeInTheDocument()
    expect(screen.getByTestId('world-visualizer')).toBeInTheDocument()
    expect(document.querySelectorAll('[data-cockpit-plane]')).toHaveLength(5)
    expect(document.querySelector('[data-cockpit-plane="work"]')).toHaveTextContent('1 blocked')
    expect(document.querySelector('[data-cockpit-plane="ide"]')).toHaveTextContent('Source')
  })

  it('links cockpit entries to their canonical production routes', () => {
    render(h(Cockpit, null))

    const goalTree = screen.getByRole('link', { name: /Open Goal Tree in #workspace \/ planning \/ goal-tree/ })
    expect(goalTree).toHaveAttribute('href', '#workspace?section=planning&view=goal-tree')

    fireEvent.click(goalTree)
    expect(route.value).toMatchObject({
      tab: 'workspace',
      params: { section: 'planning', view: 'goal-tree' },
    })
  })
})
