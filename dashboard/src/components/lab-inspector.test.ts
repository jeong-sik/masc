import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

async function loadInspector() {
  vi.resetModules()
  vi.doMock('./feature-health', () => ({
    FeatureHealth: () => html`<div data-testid="feature-health">FeatureHealth</div>`,
  }))
  vi.doMock('./server-config', () => ({
    ServerConfig: () => html`<div data-testid="server-config">ServerConfig</div>`,
  }))
  return import('./lab-inspector')
}

describe('LabInspector', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
    vi.resetModules()
    vi.doUnmock('./feature-health')
    vi.doUnmock('./server-config')
  })

  it('wraps the inspector in the v2 command surface class', async () => {
    const { LabInspector } = await loadInspector()
    render(html`<${LabInspector} />`, container)
    await flushUi()

    expect(container.querySelector('.v2-command-surface')).not.toBeNull()
    expect(container.querySelector('.v2-command-panel')).not.toBeNull()
    expect(container.querySelector('.v2-command-card')).not.toBeNull()
    expect(container.querySelectorAll('.v2-command-action').length).toBeGreaterThanOrEqual(5)
  })
})
