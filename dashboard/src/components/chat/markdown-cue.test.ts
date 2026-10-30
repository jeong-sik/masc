import { describe, expect, it } from 'vitest'
import { hasMarkdownRenderCue } from './markdown-cue'

describe('hasMarkdownRenderCue', () => {
  it('covers parser-backed block and inline markdown forms', () => {
    expect(hasMarkdownRenderCue('```ts\nconst x = 1\n```')).toBe(true)
    expect(hasMarkdownRenderCue('> [!NOTE]\n> pay attention')).toBe(true)
    expect(hasMarkdownRenderCue('- first\n- second')).toBe(true)
    expect(hasMarkdownRenderCue('| a | b |\n|---|---|')).toBe(true)
    expect(hasMarkdownRenderCue('Summary with **bold** and `code`.')).toBe(true)
    expect(hasMarkdownRenderCue('https://example.com/image.png')).toBe(true)
    expect(hasMarkdownRenderCue('<svg viewBox="0 0 1 1"></svg>')).toBe(true)
  })

  it('does not route plain prose through rich markdown loading', () => {
    expect(hasMarkdownRenderCue('plain assistant prose with a normal URL https://example.com/a')).toBe(false)
    expect(hasMarkdownRenderCue('')).toBe(false)
    expect(hasMarkdownRenderCue('   ')).toBe(false)
  })
})
