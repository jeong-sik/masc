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

})
