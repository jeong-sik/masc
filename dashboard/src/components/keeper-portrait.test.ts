import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { html } from 'htm/preact'
import { render } from 'preact'
import { KeeperPortrait, keeperPortraitUrl, PORTRAIT_MAX_PX, PORTRAIT_MIN_PX } from './keeper-portrait'

async function flush() {
  await new Promise(resolve => setTimeout(resolve, 0))
}

describe('keeperPortraitUrl', () => {
  it('asks for twice the drawn size', () => {
    expect(keeperPortraitUrl('wick-tester', 32)).toBe('/api/v1/keepers/wick-tester/portrait.png?size=64')
  })

  it('stays inside the sizes the server accepts', () => {
    expect(keeperPortraitUrl('a', 1)).toBe(`/api/v1/keepers/a/portrait.png?size=${PORTRAIT_MIN_PX}`)
    expect(keeperPortraitUrl('a', 4000)).toBe(`/api/v1/keepers/a/portrait.png?size=${PORTRAIT_MAX_PX}`)
  })

  it('encodes the name as one path segment', () => {
    expect(keeperPortraitUrl('a/b c', 32)).toBe('/api/v1/keepers/a%2Fb%20c/portrait.png?size=64')
  })
})

describe('KeeperPortrait', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  const fallback = html`<span data-testid="fallback">KB</span>`

  it('reserves its box before the image arrives', () => {
    render(html`<${KeeperPortrait} name="wick-tester" sizePx=${40} fallback=${fallback} />`, container)
    const img = container.querySelector('img') as HTMLImageElement
    expect(img.getAttribute('width')).toBe('40')
    expect(img.getAttribute('height')).toBe('40')
    expect(img.getAttribute('alt')).toBe('wick-tester')
    expect(container.querySelector('[data-testid="fallback"]')).toBeNull()
  })

  it('draws the fallback after a load error, and tries again for another keeper', async () => {
    render(html`<${KeeperPortrait} name="wick-tester" sizePx=${40} fallback=${fallback} />`, container)
    container.querySelector('img')!.dispatchEvent(new Event('error'))
    await flush()
    expect(container.querySelector('img')).toBeNull()
    expect(container.querySelector('[data-testid="fallback"]')).not.toBeNull()

    render(html`<${KeeperPortrait} name="wick-other" sizePx=${40} fallback=${fallback} />`, container)
    await flush()
    expect(container.querySelector('img')?.getAttribute('alt')).toBe('wick-other')
  })
})
