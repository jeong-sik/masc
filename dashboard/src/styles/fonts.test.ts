import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

describe('keeper-v2 brand assets', () => {
  const css = readFileSync(resolve(__dirname, 'fonts.css'), 'utf8')

  it('declares the Cinzel font family', () => {
    expect(css).toContain("font-family: 'Cinzel'")
    expect(css).toContain("url('/dashboard/assets/fonts/Cinzel-Regular.ttf')")
  })

  it('declares the serif and mono faces the skin names first in its stacks', () => {
    // --font-body leads with EB Garamond, --font-mono with JetBrains Mono.
    // Without these the dashboard renders Georgia/Menlo fallbacks while the
    // prototype renders the real faces (see docs/DESIGN-PARITY.md).
    for (const face of ['EB Garamond', 'JetBrains Mono']) {
      expect(css).toContain(`font-family: '${face}'`)
    }
    // Every latin subset entry must point at a vendored file, not a CDN.
    expect(css).not.toMatch(/url\((?!'\/dashboard)/)
  })
})

describe('keeper-v2 Korean face', () => {
  const css = readFileSync(resolve(__dirname, 'fonts-noto-sans-kr.css'), 'utf8')

  it('declares Noto Sans KR as split local woff2 slices', () => {
    expect(css).toContain("font-family: 'Noto Sans KR'")
    expect(css).toContain("url('/dashboard/assets/fonts/NotoSansKR-")
    expect(css).not.toContain('fonts.gstatic.com')
  })

  it('declares the AC00 syllable block so visible Korean text resolves locally', () => {
    // The Hangul syllables range starts at U+AC00; a slice must claim it or
    // every Korean label falls through to the system stack.
    expect(css).toMatch(/U\+ac00/)
  })
})
