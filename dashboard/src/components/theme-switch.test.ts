// @ts-nocheck
// @vitest-environment happy-dom
import { describe, expect, it, beforeEach } from 'vitest'
import { render, h } from 'preact'
import { ThemeSwitch } from './theme-switch'

describe('ThemeSwitch', () => {
  beforeEach(() => {
    delete document.documentElement.dataset.theme
    localStorage.clear()
    window.history.replaceState(null, '', '/')
  })

  it('renders DARK label when no theme attribute is set', () => {
    const container = document.createElement('div')
    render(h(ThemeSwitch), container)
    expect(container.textContent).toContain('DARK')
  })

  it('renders SEED label when StyleSeed theme is active', () => {
    document.documentElement.dataset.theme = 'styleseed'
    const container = document.createElement('div')
    render(h(ThemeSwitch), container)
    expect(container.textContent).toContain('SEED')
  })

  it('toggles from styleseed to paper on click', () => {
    document.documentElement.dataset.theme = 'styleseed'
    window.history.replaceState(null, '', '/?theme=styleseed')
    const container = document.createElement('div')
    render(h(ThemeSwitch), container)
    const btn = container.querySelector('button')
    expect(btn).not.toBeNull()
    btn!.click()
    expect(document.documentElement.dataset.theme).toBe('paper')
    expect(localStorage.getItem('dashboardTheme')).toBe('paper')
    expect(window.location.search).toContain('theme=paper')
  })

  it('toggles from dark to styleseed on click', () => {
    const container = document.createElement('div')
    render(h(ThemeSwitch), container)
    const btn = container.querySelector('button')
    btn!.click()
    expect(document.documentElement.dataset.theme).toBe('styleseed')
    expect(localStorage.getItem('dashboardTheme')).toBe('styleseed')
    expect(window.location.search).toContain('theme=styleseed')
  })

  it('has correct aria-label for styleseed', () => {
    document.documentElement.dataset.theme = 'styleseed'
    const container = document.createElement('div')
    render(h(ThemeSwitch), container)
    const btn = container.querySelector('button')
    expect(btn!.getAttribute('aria-label')).toContain('StyleSeed')
    expect(btn!.getAttribute('title')).toContain('StyleSeed')
  })

  it('has correct aria-label for default', () => {
    const container = document.createElement('div')
    render(h(ThemeSwitch), container)
    const btn = container.querySelector('button')
    expect(btn!.getAttribute('aria-label')).toContain('StyleSeed')
    expect(btn!.getAttribute('title')).toContain('StyleSeed')
  })

  it('carries the v2 shell action marker', () => {
    const container = document.createElement('div')
    render(h(ThemeSwitch), container)
    const btn = container.querySelector('button')
    expect(btn!.classList.contains('v2-shell-action')).toBe(true)
  })

  it('toggles from paper to dark on click', () => {
    document.documentElement.dataset.theme = 'paper'
    window.history.replaceState(null, '', '/?theme=paper')
    const container = document.createElement('div')
    render(h(ThemeSwitch), container)
    const btn = container.querySelector('button')
    btn!.click()
    expect(document.documentElement.dataset.theme).toBeUndefined()
    expect(localStorage.getItem('dashboardTheme')).toBeNull()
    expect(window.location.search).not.toContain('theme=paper')
  })
})
