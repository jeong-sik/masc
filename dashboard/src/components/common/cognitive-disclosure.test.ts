import { h } from 'preact'
import { cleanup, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import '@testing-library/jest-dom'

import {
  CognitiveDisclosure,
  summarizeCognitiveDisclosure,
  type CognitiveDisclosureItem,
} from './cognitive-disclosure'

const ITEMS: CognitiveDisclosureItem[] = [
  {
    level: 'perceive',
    title: 'Route coverage',
    summary: '12 routes',
    metric: '12',
    detail: h('span', null, 'Live route counts'),
    defaultOpen: true,
  },
  {
    level: 'comprehend',
    title: 'Plane grouping',
    summary: 'Work and Observe',
    metric: '2',
  },
  {
    level: 'project',
    title: 'Next route',
    summary: '1 blocked',
    detail: h('span', null, 'Blocked route gap'),
  },
]

describe('CognitiveDisclosure', () => {
  afterEach(() => cleanup())

  it('summarizes items by disclosure level', () => {
    expect(summarizeCognitiveDisclosure(ITEMS)).toEqual({
      total: 3,
      byLevel: {
        perceive: 1,
        comprehend: 1,
        project: 1,
      },
      openDefaultLevel: 'perceive',
      complete: true,
    })
  })

  it('renders stable disclosure metadata for all levels', () => {
    render(h(CognitiveDisclosure, { items: ITEMS, testId: 'disclosure' }))

    const root = screen.getByTestId('disclosure')
    expect(root).toHaveAttribute('data-cognitive-total', '3')
    expect(root).toHaveAttribute('data-cognitive-complete', 'true')
    expect(root).toHaveAttribute('data-cognitive-open-default', 'perceive')
    expect(root.querySelectorAll('[data-cognitive-level]')).toHaveLength(3)
    expect(root.querySelector('[data-cognitive-level="project"]')).toHaveAttribute('data-cognitive-count', '1')
    expect(screen.getByText('Perceive')).toBeInTheDocument()
    expect(screen.getByText('Comprehend')).toBeInTheDocument()
    expect(screen.getByText('Project')).toBeInTheDocument()
  })

  it('marks rows that have expandable detail content', () => {
    render(h(CognitiveDisclosure, { items: ITEMS, testId: 'disclosure' }))

    const root = screen.getByTestId('disclosure')
    const routeCoverage = root.querySelector('details[data-cognitive-has-detail="true"]')
    const planeGrouping = screen.getByText('Plane grouping').closest('[data-cognitive-has-detail]')

    expect(routeCoverage).toHaveTextContent('Live route counts')
    expect(planeGrouping).toHaveAttribute('data-cognitive-has-detail', 'false')
    expect(planeGrouping?.tagName.toLowerCase()).toBe('div')
  })
})
