// @ts-nocheck
// @vitest-environment happy-dom
import { describe, expect, it, beforeEach } from 'vitest'
import { render, h } from 'preact'
import { ThemeSwitch } from './theme-switch'

describe('ThemeSwitch', () => {
  beforeEach(() => {
    delete document.documentElement.dataset.theme
    localStorage.clear()
  })

  it('renders DARK label by default', () => {
    const container = document.createElement('div')
    render(h(ThemeSwitch), container)
    expect(container.textContent).toContain('DARK')
  })

  it('toggles to paper on click from default', () => {
    const container = document.createElement('div')
    render(h(ThemeSwitch), container)
    const btn = container.querySelector('button')
    expect(btn).not.toBeNull()
    btn!.click()
    expect(document.documentElement.dataset.theme).toBe('paper')
    expect(localStorage.getItem('dashboardTheme')).toBe('paper')
  })

  it('toggles back to dark on second click', () => {
    document.documentElement.dataset.theme = 'paper'
    const container = document.createElement('div')
    render(h(ThemeSwitch), container)
    const btn = container.querySelector('button')
    btn!.click()
    expect(document.documentElement.dataset.theme).toBeUndefined()
    expect(localStorage.getItem('dashboardTheme')).toBeNull()
  })

  it('has correct aria-label for default', () => {
    const container = document.createElement('div')
    render(h(ThemeSwitch), container)
    const btn = container.querySelector('button')
    expect(btn!.getAttribute('aria-label')).toContain('Dark')
    expect(btn!.getAttribute('title')).toContain('Dark')
  })

  it('has correct aria-label after toggling to paper', () => {
    const container = document.createElement('div')
    render(h(ThemeSwitch), container)
    const btn = container.querySelector('button')
    btn!.click()
    expect(btn!.getAttribute('aria-label')).toContain('Paper')
    expect(btn!.getAttribute('title')).toContain('Paper')
  })
})
