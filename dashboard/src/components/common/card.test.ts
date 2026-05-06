// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  SurfaceCard,
  SectionCard,
  Card,
  summarizeSurfaceCard,
  summarizeSectionCard,
  sectionCardStatusDotTone,
} from './card'

describe('summarizeSurfaceCard', () => {
  it('summarizes default surface card state', () => {
    expect(summarizeSurfaceCard({ children: 'Content' })).toEqual({
      variant: 'standard',
      tone: '',
      toneSource: 'none',
      hasTone: false,
      toneLength: 0,
      hasCustomClass: false,
      classNameLength: 0,
      hasTestId: false,
      testIdLength: 0,
      contentState: 'text',
    })
  })

  it('summarizes populated surface card state', () => {
    expect(summarizeSurfaceCard({
      variant: 'compact',
      tone: 'ok',
      class: 'extra-card',
      testId: 'card-1',
      children: h('span', null, 'Node'),
    })).toEqual({
      variant: 'compact',
      tone: 'ok',
      toneSource: 'tone-class',
      hasTone: true,
      toneLength: 2,
      hasCustomClass: true,
      classNameLength: 10,
      hasTestId: true,
      testIdLength: 6,
      contentState: 'node',
    })
  })
})

describe('summarizeSectionCard', () => {
  it('summarizes status-eyebrow section state', () => {
    expect(summarizeSectionCard({
      title: 'Transport',
      status: 'Watch',
      eyebrow: 'observing',
      tone: 'warn',
      variant: 'compact',
      class: 'wide',
      testId: 'section-a',
      children: h('p', null, 'Body'),
    })).toEqual({
      variant: 'compact',
      bodyPadding: 'p-3.5',
      labelSource: 'title',
      labelState: 'text',
      labelTextLength: 9,
      tailSource: 'status-eyebrow',
      status: 'Watch',
      normalizedStatus: 'watch',
      statusDotTone: 'warn',
      hasStatus: true,
      statusLength: 5,
      hasEyebrow: true,
      eyebrowState: 'text',
      eyebrowTextLength: 9,
      hasRightSlot: false,
      hasTone: true,
      toneLength: 4,
      hasCustomClass: true,
      classNameLength: 4,
      hasTestId: true,
      testIdLength: 9,
      contentState: 'node',
    })
  })

  it('summarizes explicit right slot state', () => {
    expect(summarizeSectionCard({
      label: 'Queue',
      right: h('button', null, 'Refresh'),
      children: 'Body',
    }).tailSource).toBe('right')
  })

  it('treats blank string metadata as absent', () => {
    expect(summarizeSurfaceCard({
      tone: '  ',
      class: ' ',
      testId: '\t',
      children: 'Body',
    })).toMatchObject({
      hasTone: false,
      toneLength: 0,
      hasCustomClass: false,
      classNameLength: 0,
      hasTestId: false,
      testIdLength: 0,
    })

    expect(summarizeSectionCard({
      title: 'Queue',
      status: '  ',
      tone: ' ',
      testId: ' ',
      children: 'Body',
    })).toMatchObject({
      tailSource: 'none',
      normalizedStatus: '',
      hasStatus: false,
      statusLength: 0,
      hasTone: false,
      hasTestId: false,
    })
  })

  it('keeps status length aligned to normalized status metadata', () => {
    expect(summarizeSectionCard({
      title: 'Queue',
      status: ' Watch ',
      children: 'Body',
    })).toMatchObject({
      tailSource: 'status-eyebrow',
      normalizedStatus: 'watch',
      hasStatus: true,
      statusLength: 5,
    })
  })
})

describe('sectionCardStatusDotTone', () => {
  it('keeps section-specific status aliases stable', () => {
    expect(sectionCardStatusDotTone('healthy')).toBe('ok')
    expect(sectionCardStatusDotTone('live')).toBe('ok')
    expect(sectionCardStatusDotTone('watch')).toBe('warn')
    expect(sectionCardStatusDotTone('danger')).toBe('bad')
    expect(sectionCardStatusDotTone('offline')).toBe('neutral')
  })
})

describe('SurfaceCard', () => {
  it('renders children', () => {
    const container = document.createElement('div')
    render(h(SurfaceCard, null, 'Content'), container)
    expect(container.textContent).toContain('Content')
    const el = container.querySelector('[data-surface-card]')
    expect(el).not.toBeNull()
    expect(el?.getAttribute('data-surface-card-variant')).toBe('standard')
    expect(el?.getAttribute('data-surface-card-content-state')).toBe('text')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(SurfaceCard, { testId: 'card-1' }, 'A'), container)
    const el = container.querySelector('[data-testid="card-1"]')
    expect(el).not.toBeNull()
    expect(el?.getAttribute('data-surface-card-has-test-id')).toBe('true')
    expect(el?.getAttribute('data-surface-card-test-id-length')).toBe('6')
  })

  it('applies standard variant class', () => {
    const container = document.createElement('div')
    render(h(SurfaceCard, { variant: 'standard' }, 'A'), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('card')).toBe(true)
    expect(el?.getAttribute('data-surface-card-variant')).toBe('standard')
  })

  it('applies light variant class', () => {
    const container = document.createElement('div')
    render(h(SurfaceCard, { variant: 'light' }, 'A'), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('!bg-transparent')).toBe(true)
    expect(el?.getAttribute('data-surface-card-variant')).toBe('light')
  })

  it('applies compact variant class', () => {
    const container = document.createElement('div')
    render(h(SurfaceCard, { variant: 'compact' }, 'A'), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('!p-3.5')).toBe(true)
    expect(el?.getAttribute('data-surface-card-variant')).toBe('compact')
  })

  it('applies tone class', () => {
    const container = document.createElement('div')
    render(h(SurfaceCard, { tone: 'ok' }, 'A'), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('ok')).toBe(true)
    expect(el?.getAttribute('data-surface-card-tone')).toBe('ok')
    expect(el?.getAttribute('data-surface-card-tone-source')).toBe('tone-class')
    expect(el?.getAttribute('data-surface-card-has-tone')).toBe('true')
    expect(el?.getAttribute('data-surface-card-tone-length')).toBe('2')
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(SurfaceCard, { class: 'extra' }, 'A'), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('extra')).toBe(true)
    expect(el?.getAttribute('data-surface-card-has-custom-class')).toBe('true')
    expect(el?.getAttribute('data-surface-card-class-length')).toBe('5')
  })
})

describe('SectionCard', () => {
  it('renders label and children', () => {
    const container = document.createElement('div')
    render(h(SectionCard, { label: 'Section A' }, h('p', null, 'Body')), container)
    expect(container.textContent).toContain('Section A')
    expect(container.textContent).toContain('Body')
    const el = container.querySelector('[data-section-card]')
    expect(el).not.toBeNull()
    expect(el?.getAttribute('data-section-card-label-source')).toBe('label')
    expect(el?.getAttribute('data-section-card-label-state')).toBe('text')
    expect(el?.getAttribute('data-section-card-label-text-length')).toBe('9')
    expect(el?.getAttribute('data-section-card-tail-source')).toBe('none')
    expect(el?.getAttribute('data-section-card-content-state')).toBe('node')
  })

  it('applies compact body padding', () => {
    const container = document.createElement('div')
    render(h(SectionCard, { label: 'T', variant: 'compact' }, 'Body'), container)
    expect(container.innerHTML).toContain('p-3.5')
    expect(container.querySelector('[data-section-card]')?.getAttribute('data-section-card-body-padding')).toBe('p-3.5')
  })

  it('accepts legacy title, right slot, and test id props', () => {
    const container = document.createElement('div')
    render(
      h(
        SectionCard,
        { title: 'Section B', right: h('span', null, 'Tail'), testId: 'section-b' },
        h('p', null, 'Body'),
      ),
      container,
    )
    const el = container.querySelector('[data-testid="section-b"]')
    expect(el).not.toBeNull()
    expect(el?.getAttribute('data-section-card-label-source')).toBe('title')
    expect(el?.getAttribute('data-section-card-tail-source')).toBe('right')
    expect(el?.getAttribute('data-section-card-has-right-slot')).toBe('true')
    expect(el?.getAttribute('data-section-card-has-test-id')).toBe('true')
    expect(el?.getAttribute('data-section-card-test-id-length')).toBe('9')
    expect(container.textContent).toContain('Section B')
    expect(container.textContent).toContain('Tail')
    expect(container.textContent).toContain('Body')
  })

  it('renders status and eyebrow when no right slot is provided', () => {
    const container = document.createElement('div')
    render(
      h(
        SectionCard,
        { title: 'Transport', status: 'warn', eyebrow: 'degraded' },
        h('p', null, 'Body'),
      ),
      container,
    )
    expect(container.textContent).toContain('Transport')
    expect(container.textContent).toContain('degraded')
    expect(container.innerHTML).toContain('bg-[var(--color-status-warn)]')
    const el = container.querySelector('[data-section-card]')
    expect(el?.getAttribute('data-section-card-status')).toBe('warn')
    expect(el?.getAttribute('data-section-card-status-dot-tone')).toBe('warn')
    expect(el?.getAttribute('data-section-card-tail-source')).toBe('status-eyebrow')
    expect(el?.getAttribute('data-section-card-has-status')).toBe('true')
    expect(el?.getAttribute('data-section-card-has-eyebrow')).toBe('true')
    expect(el?.getAttribute('data-section-card-eyebrow-text-length')).toBe('8')
  })

  it('normalizes watch status before choosing the dot tone', () => {
    const container = document.createElement('div')
    render(
      h(
        SectionCard,
        { title: 'Transport', status: ' Watch ', eyebrow: 'observing' },
        h('p', null, 'Body'),
      ),
      container,
    )
    expect(container.innerHTML).toContain('bg-[var(--color-status-warn)]')
    const el = container.querySelector('[data-section-card]')
    expect(el?.getAttribute('data-section-card-status')).toBe('watch')
    expect(el?.getAttribute('data-section-card-status-length')).toBe('5')
  })

  it('maps offline status through the shared neutral dot tone', () => {
    const container = document.createElement('div')
    render(
      h(
        SectionCard,
        { title: 'Transport', status: 'offline', eyebrow: 'not connected' },
        h('p', null, 'Body'),
      ),
      container,
    )
    expect(container.innerHTML).toContain('bg-[var(--color-status-idle)]')
  })
})

describe('Card', () => {
  it('renders as SurfaceCard without title', () => {
    const container = document.createElement('div')
    render(h(Card, null, 'Content'), container)
    expect(container.textContent).toContain('Content')
  })

  it('renders as SectionCard with title', () => {
    const container = document.createElement('div')
    render(h(Card, { title: 'Header' }, 'Body'), container)
    expect(container.textContent).toContain('Header')
    expect(container.textContent).toContain('Body')
  })
})
