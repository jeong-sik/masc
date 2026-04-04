import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ErrorBoundary } from './error-boundary'

void vi

function Boom() {
  throw new Error('boom')
}

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

describe('ErrorBoundary', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.restoreAllMocks()
  })

  it('renders the retry action with the shared card border token after a render error', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})

    expect(() => {
      render(html`<${ErrorBoundary} label="overview"><${Boom} /><//>`, container)
    }).not.toThrow()
    await flushUi()

    const button = container.querySelector('button')
    expect(button).not.toBeNull()
    expect(button?.className).toContain('border-[var(--card-border)]')
    expect(button?.className).not.toContain('card rounded-xl-border')
  })
})
