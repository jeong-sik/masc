import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

// The document theme attribute is written by the bootstrap (main.ts) and the
// runtime toggle (theme-switch.ts). Both speak the same vocabulary, ThemeId --
// 'styleseed' | 'paper' | null -- and share the storage keys through
// lib/theme.ts, so restoring and toggling agree.
//
// A third writer did not. An app.ts effect wrote the same attribute from
// tweaksTheme, whose vocabulary is 'dark' | 'paper', so selecting styleseed and
// reloading rewrote it to '' and the choice vanished (#22899). The type checker
// could not see it: each writer was individually valid.
//
// This pins who may write it. Adding a writer that does not speak ThemeId is
// the thing that broke.
const SOURCES = [
  'src/app.ts',
  'src/main.ts',
  'src/components/theme-switch.ts',
  'src/components/tweaks-panel.ts',
]

const DOCUMENT_THEME_WRITE =
  /document\.documentElement\.(?:dataset\.theme\s*=|setAttribute\(\s*['"]data-theme['"])/g

function writesIn(file: string): number {
  const source = readFileSync(resolve(process.cwd(), file), 'utf8')
  return source.match(DOCUMENT_THEME_WRITE)?.length ?? 0
}

describe('document theme attribute ownership', () => {
  it('is written only by the two modules that speak ThemeId', () => {
    const owners = SOURCES.filter((file) => writesIn(file) > 0)
    expect(owners).toEqual(['src/main.ts', 'src/components/theme-switch.ts'])
  })

  it('both writers import the shared vocabulary', () => {
    // The claim is not "two writers" but "two writers that agree". Each has to
    // reach ThemeId and the storage keys through lib/theme.
    for (const file of ['src/main.ts', 'src/components/theme-switch.ts']) {
      const source = readFileSync(resolve(process.cwd(), file), 'utf8')
      expect(source, file).toContain('THEME_STORAGE_KEYS')
      expect(source, file).toContain('ThemeId')
    }
  })

  it('leaves the app element free to carry its own data-theme', () => {
    // The app element is app-scoped, not the document root, so it is not part
    // of the ownership claim above; this pins that distinction.
    const source = readFileSync(resolve(process.cwd(), 'src/app.ts'), 'utf8')
    expect(source).toContain('data-theme=${tweaksTheme.value')
    expect(writesIn('src/app.ts')).toBe(0)
  })
})
