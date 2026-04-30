// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { AgentTrust } from './agent-trust'

describe('AgentTrust a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly with high score', async () => {
    render(
      html`<${AgentTrust} metrics=${{ score: 90, approvals: 10, rejections: 1, overrides: 0 }} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with medium score', async () => {
    render(
      html`<${AgentTrust} metrics=${{ score: 60, approvals: 5, rejections: 3, overrides: 2 }} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with low score', async () => {
    render(
      html`<${AgentTrust} metrics=${{ score: 30, approvals: 1, rejections: 8, overrides: 1 }} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with zero metrics', async () => {
    render(
      html`<${AgentTrust} metrics=${{ score: 0, approvals: 0, rejections: 0, overrides: 0 }} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has role=meter with correct aria values', () => {
    render(
      html`<${AgentTrust} metrics=${{ score: 75, approvals: 3, rejections: 1, overrides: 0 }} />`,
      container,
    )
    const meter = container.querySelector('[role="meter"]')
    expect(meter).not.toBeNull()
    expect(meter?.getAttribute('aria-valuemin')).toBe('0')
    expect(meter?.getAttribute('aria-valuemax')).toBe('100')
    expect(meter?.getAttribute('aria-valuenow')).toBe('75')
    expect(meter?.getAttribute('aria-label')).toBe('신뢰도 점수')
  })

  it('clamps score to 0-100 range', () => {
    render(
      html`<${AgentTrust} metrics=${{ score: 150, approvals: 1, rejections: 0, overrides: 0 }} />`,
      container,
    )
    const meter = container.querySelector('[role="meter"]')
    expect(meter?.getAttribute('aria-valuenow')).toBe('100')
  })

  it('renders approval, rejection, override counts', () => {
    render(
      html`<${AgentTrust} metrics=${{ score: 50, approvals: 7, rejections: 2, overrides: 1 }} />`,
      container,
    )
    expect(container.textContent).toContain('7')
    expect(container.textContent).toContain('2')
    expect(container.textContent).toContain('1')
    expect(container.textContent).toContain('승인률: 70.0% (10회 평가)')
  })
})
