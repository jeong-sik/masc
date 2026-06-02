// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Terminal } from './terminal'

describe('Terminal a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const makeLines = (): import('./terminal').TerminalLine[] => [
    { text: '\x1b[1;32mMASC Agent Terminal\x1b[0m v0.4.0' },
    { text: 'Loading modules...' },
    { text: '\x1b[31mError:\x1b[0m connection timeout' },
    { text: '\x1b[33mWarning:\x1b[0m high latency' },
  ]

  it('renders accessibly with lines', async () => {
    render(html`<${Terminal} lines=${makeLines()} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with empty lines', async () => {
    render(html`<${Terminal} lines=${[]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with custom prompt', async () => {
    render(html`<${Terminal} lines=${makeLines()} prompt="root# " />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has log role with aria-live', () => {
    render(html`<${Terminal} lines=${makeLines()} />`, container)
    const log = container.querySelector('[role="log"]')
    expect(log).not.toBeNull()
    expect(log?.getAttribute('aria-live')).toBe('polite')
  })

  it('renders prompt text', () => {
    render(html`<${Terminal} lines=${[]} prompt="agent:$ " />`, container)
    expect(container.textContent).toContain('agent:$')
  })

  it('renders ANSI colored content', () => {
    render(html`<${Terminal} lines=${makeLines()} />`, container)
    expect(container.textContent).toContain('MASC Agent Terminal')
    expect(container.textContent).toContain('connection timeout')
    expect(container.textContent).toContain('high latency')
  })
})
