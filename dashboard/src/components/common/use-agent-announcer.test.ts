// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { useAgentAnnouncer } from './use-agent-announcer'

function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

function AnnouncerTester({ output }: { output?: Parameters<ReturnType<typeof useAgentAnnouncer>['announceAgentOutput']>[0] }) {
  const { announce, announceAgentOutput } = useAgentAnnouncer()
  return html`
    <div>
      <button data-testid="polite" onClick=${() => announce('polite message', 'polite')}>polite</button>
      <button data-testid="assertive" onClick=${() => announce('assertive message', 'assertive')}>assertive</button>
      <button data-testid="output" onClick=${() => output && announceAgentOutput(output)}>output</button>
    </div>
  `
}

describe('useAgentAnnouncer', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    const polite = document.createElement('div')
    polite.id = 'live-region-polite'
    document.body.appendChild(polite)
    const assertive = document.createElement('div')
    assertive.id = 'live-region-assertive'
    document.body.appendChild(assertive)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    document.getElementById('live-region-polite')?.remove()
    document.getElementById('live-region-assertive')?.remove()
  })

  it('announces polite message', async () => {
    render(html`<${AnnouncerTester} />`, container)
    await tick()
    const btn = container.querySelector('[data-testid="polite"]') as HTMLElement
    btn.click()
    await tick()
    expect(document.getElementById('live-region-polite')?.textContent).toBe('polite message')
  })

  it('announces assertive message', async () => {
    render(html`<${AnnouncerTester} />`, container)
    await tick()
    const btn = container.querySelector('[data-testid="assertive"]') as HTMLElement
    btn.click()
    await tick()
    expect(document.getElementById('live-region-assertive')?.textContent).toBe('assertive message')
  })

  it('announces code output summary', async () => {
    render(html`<${AnnouncerTester} output=${{ type: 'code', content: 'const x = 1\nconst y = 2', metadata: { language: 'ts', lineCount: 2 } }} />`, container)
    await tick()
    const btn = container.querySelector('[data-testid="output"]') as HTMLElement
    btn.click()
    await tick()
    const region = document.getElementById('live-region-polite')
    expect(region?.textContent).toContain('Code output')
    expect(region?.textContent).toContain('ts')
    expect(region?.textContent).toContain('2 lines')
  })

  it('uses assertive for error output', async () => {
    render(html`<${AnnouncerTester} output=${{ type: 'error', content: 'Connection failed' }} />`, container)
    await tick()
    const btn = container.querySelector('[data-testid="output"]') as HTMLElement
    btn.click()
    await tick()
    expect(document.getElementById('live-region-assertive')?.textContent).toContain('Connection failed')
  })
})
