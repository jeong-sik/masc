import { describe, expect, it } from 'vitest'
import { readFileSync, readdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)
const projectRoot = resolve(__dirname, '../..')

describe('keeper-v2 brand assets', () => {
  const css = readFileSync(resolve(__dirname, 'fonts.css'), 'utf8')

  it('declares the Cinzel font family', () => {
    expect(css).toContain("font-family: 'Cinzel'")
    expect(css).toContain("url('/dashboard/assets/fonts/Cinzel-Regular.ttf')")
  })

  it('does not declare the large local Noto Sans KR TTF on the hot path', () => {
    expect(css).not.toContain('NotoSansKR-Regular.ttf')
  })

  it('lists all expected keeper portraits in the public directory', () => {
    const portraitDir = resolve(projectRoot, 'public/assets/keepers/portraits')
    const files = readdirSync(portraitDir)
      .filter((name) => name.endsWith('.png'))
      .sort()

    expect(files).toEqual([
      'aldric.png',
      'bell.png',
      'brenna.png',
      'cedric.png',
      'dara.png',
      'dust.png',
      'grimja.png',
      'iron.png',
      'luna.png',
      'miso.png',
      'moth.png',
      'songarak.png',
    ])
  })
})
