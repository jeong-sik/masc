// @vitest-environment happy-dom
import { describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { ExcusePatterns } from './excuse-patterns'

vi.mock('../api/dashboard', () => ({
  fetchExcusePatterns: vi.fn().mockResolvedValue([]),
  updateExcusePatterns: vi.fn().mockResolvedValue(undefined),
}))

const flush = () => new Promise<void>((r) => setTimeout(() => r(), 10))

describe('ExcusePatterns', () => {
  it('renders the v2 command panel marker', async () => {
    const container = document.createElement('div')
    render(html`<${ExcusePatterns} />`, container)
    await flush()

    expect(container.querySelector('.v2-command-panel')).not.toBeNull()
  })
})
