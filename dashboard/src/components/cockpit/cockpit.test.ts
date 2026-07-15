import { h } from 'preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import '@testing-library/jest-dom'

import { route } from '../../router'
import { COCKPIT_ENTRYPOINTS } from '../../cockpit-entrypoints'
import { Cockpit } from './cockpit'

describe('Cockpit command map', () => {
  beforeEach(() => {
    window.location.hash = '#cockpit'
    route.value = { tab: 'cockpit', params: {}, postId: null }
  })

  afterEach(() => {
    cleanup()
    window.location.hash = ''
    route.value = { tab: 'overview', params: {}, postId: null }
  })

  it('renders one route section per cockpit plane', () => {
    render(h(Cockpit, null))

    expect(screen.getByTestId('cockpit-command-map')).toBeInTheDocument()
    expect(screen.getByTestId('cockpit-disclosure')).toBeInTheDocument()
    expect(document.querySelectorAll('[data-cockpit-plane]')).toHaveLength(5)
    expect(document.querySelector('[data-cockpit-plane="work"]')).toHaveTextContent('2 covered')
    expect(document.querySelector('[data-cockpit-plane="ide"]')).toHaveTextContent('Source')

    expect(document.querySelector('.cp-body')).not.toBeNull()
    expect(document.querySelector('.cp-head')).not.toBeNull()
    expect(document.querySelector('.cp-disc')).not.toBeNull()
    expect(document.querySelectorAll('.cp-plane')).toHaveLength(5)
    expect(document.querySelectorAll('.cp-route')).toHaveLength(COCKPIT_ENTRYPOINTS.length)
  })

  it('renders progressive disclosure levels over the route map', () => {
    render(h(Cockpit, null))

    const disclosure = screen.getByTestId('cockpit-disclosure')
    expect(disclosure.querySelectorAll('[data-cockpit-disclosure-level]')).toHaveLength(3)
    expect(disclosure.querySelector('[data-cockpit-disclosure-level="perceive"]')).toHaveTextContent('Route coverage')
    expect(disclosure.querySelector('[data-cockpit-disclosure-level="comprehend"]')).toHaveTextContent('Plane grouping')
    expect(disclosure.querySelector('[data-cockpit-disclosure-level="project"]')).toHaveTextContent('Route gaps')
    expect(disclosure).toHaveTextContent('10 routes')
    expect(disclosure).toHaveTextContent('No backend-blocked routes')
  })

  it('links cockpit entries to their canonical production routes', () => {
    render(h(Cockpit, null))

    const taskBoard = screen.getByRole('link', { name: /Open Task Board in #workspace \/ planning/ })
    expect(taskBoard).toHaveAttribute('href', '#workspace?section=planning')

    fireEvent.click(taskBoard)
    expect(route.value).toMatchObject({
      tab: 'workspace',
      params: { section: 'planning' },
    })
  })
})
