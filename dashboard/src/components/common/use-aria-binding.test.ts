// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { useARIABinding } from './use-aria-binding'

function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

function BindingTester() {
  const { triggerId, contentId, titleId, descriptionId } = useARIABinding()
  return html`
    <div>
      <button id=${triggerId} aria-controls=${contentId} data-testid="trigger">Trigger</button>
      <div id=${contentId} role="dialog" aria-labelledby=${titleId} aria-describedby=${descriptionId} data-testid="content">Content</div>
      <h2 id=${titleId} data-testid="title">Title</h2>
      <p id=${descriptionId} data-testid="desc">Description</p>
    </div>
  `
}

describe('useARIABinding', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('generates unique IDs for each binding instance', async () => {
    render(html`<${BindingTester} />`, container)
    await tick()

    const trigger = container.querySelector('[data-testid="trigger"]') as HTMLElement
    const content = container.querySelector('[data-testid="content"]') as HTMLElement
    const title = container.querySelector('[data-testid="title"]') as HTMLElement
    const desc = container.querySelector('[data-testid="desc"]') as HTMLElement

    expect(trigger.id).not.toBe('')
    expect(content.id).not.toBe('')
    expect(title.id).not.toBe('')
    expect(desc.id).not.toBe('')

    // IDs should be distinct
    const ids = [trigger.id, content.id, title.id, desc.id]
    expect(new Set(ids).size).toBe(4)
  })

  it('links trigger to content via aria-controls', async () => {
    render(html`<${BindingTester} />`, container)
    await tick()

    const trigger = container.querySelector('[data-testid="trigger"]') as HTMLElement
    const content = container.querySelector('[data-testid="content"]') as HTMLElement

    expect(trigger.getAttribute('aria-controls')).toBe(content.id)
  })

  it('links content to title and description', async () => {
    render(html`<${BindingTester} />`, container)
    await tick()

    const content = container.querySelector('[data-testid="content"]') as HTMLElement
    const title = container.querySelector('[data-testid="title"]') as HTMLElement
    const desc = container.querySelector('[data-testid="desc"]') as HTMLElement

    expect(content.getAttribute('aria-labelledby')).toBe(title.id)
    expect(content.getAttribute('aria-describedby')).toBe(desc.id)
  })
})
