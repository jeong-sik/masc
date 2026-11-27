import { describe, expect, it } from 'vitest'
import { cssColorLiterals, decorateColorLiterals } from './color-swatch'

const swatchColors = (root: HTMLElement) =>
  [...root.querySelectorAll<HTMLElement>('.md-color-swatch')].map(swatch => swatch.style.backgroundColor)

describe('cssColorLiterals', () => {
  it('reads #RRGGBB outside comments and strings only', () => {
    const css = '/* #ffffff */ a { content: "#000000"; color:#1D4ED8; border:#abcdef1; outline:#fff; fill:#11223344; mask:url(a.svg#abcdef) }\n:root { --bg: #f8fafc; }'
    expect(cssColorLiterals(css).map(literal => literal.color)).toEqual(['#1D4ED8', '#f8fafc'])
    // An escaped quote does not close the string; an unclosed comment runs to the end.
    expect(cssColorLiterals('a { content: "\\" #000000"; color: #111111 } /* #222222')
      .map(literal => literal.color)).toEqual(['#111111'])
  })
})

describe('decorateColorLiterals', () => {
  it('marks whole-literal inline code and every literal in a css fence, and restores the DOM', () => {
    const root = document.createElement('div')
    root.innerHTML = [
      '<p><code>#1e1e2e</code> <code>#1e1e2e;</code> <code>1e1e2e</code></p>',
      '<pre><code class="language-css">:root { --bg: #f8fafc; --text: #0f172a; }</code></pre>',
      '<pre><code class="language-CSS">a { color: #333333 }</code></pre>',
      '<pre><code class="language-toml">color: #f8fafc</code></pre>',
    ].join('')
    const before = root.innerHTML
    const textBefore = root.textContent

    const restore = decorateColorLiterals(root)

    expect(swatchColors(root)).toEqual(['#1e1e2e', '#f8fafc', '#0f172a', '#333333'])
    expect(root.querySelector('p code')?.firstElementChild?.className).toBe('md-color-swatch')
    expect(root.querySelector('.language-toml .md-color-swatch')).toBeNull()
    expect(root.textContent).toBe(textBefore)

    restore()
    expect(root.innerHTML).toBe(before)
    expect(root.querySelector('.language-css')?.childNodes).toHaveLength(1)
  })
})
