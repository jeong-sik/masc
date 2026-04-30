// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { ThemeProvider, useTheme } from './use-theme'

function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

function ThemeConsumer() {
  const { theme, setTheme, systemPreference } = useTheme()
  return html`
    <div data-theme=${theme} data-system=${systemPreference} data-testid="consumer">
      <button data-testid="dark" onClick=${() => setTheme('dark')}>dark</button>
      <button data-testid="light" onClick=${() => setTheme('light')}>light</button>
    </div>
  `
}

describe('useTheme', () => {
  let container: HTMLElement
  const originalGetItem = Storage.prototype.getItem
  const originalSetItem = Storage.prototype.setItem

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    let store: Record<string, string> = {}
    Storage.prototype.getItem = (key: string) => store[key] ?? null
    Storage.prototype.setItem = (key: string, value: string) => {
      store[key] = value
    }
    document.documentElement.removeAttribute('data-theme')
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    Storage.prototype.getItem = originalGetItem
    Storage.prototype.setItem = originalSetItem
    document.documentElement.removeAttribute('data-theme')
  })

  it('uses default theme', async () => {
    render(html`<${ThemeProvider} defaultTheme="light"><${ThemeConsumer} /></${ThemeProvider}>`, container)
    await tick()
    const el = container.querySelector('[data-testid="consumer"]') as HTMLElement
    expect(el.getAttribute('data-theme')).toBe('light')
  })

  it('sets theme and updates document attribute', async () => {
    render(html`<${ThemeProvider} defaultTheme="dark"><${ThemeConsumer} /></${ThemeProvider}>`, container)
    await tick()
    const btn = container.querySelector('[data-testid="light"]') as HTMLElement
    btn.click()
    await tick()
    const el = container.querySelector('[data-testid="consumer"]') as HTMLElement
    expect(el.getAttribute('data-theme')).toBe('light')
    expect(document.documentElement.getAttribute('data-theme')).toBe('light')
  })

  it('persists theme to localStorage', async () => {
    render(html`<${ThemeProvider} defaultTheme="dark"><${ThemeConsumer} /></${ThemeProvider}>`, container)
    await tick()
    const btn = container.querySelector('[data-testid="light"]') as HTMLElement
    btn.click()
    await tick()
    expect(localStorage.getItem('masc-theme-v2')).toBe('light')
  })
})
