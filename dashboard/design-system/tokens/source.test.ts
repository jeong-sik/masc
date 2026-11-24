import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, it, expect } from 'vitest'
import { source, type TokenBase, type Tier, type Kind } from './source'

const RAW: readonly TokenBase[] = source.raw
const SEMANTIC: readonly TokenBase[] = source.semantic
const ALL: readonly TokenBase[] = [...RAW, ...SEMANTIC]

const VALID_TIERS: ReadonlySet<Tier> = new Set<Tier>(['raw', 'semantic', 'role'])
const VALID_KINDS: ReadonlySet<Kind> = new Set<Kind>([
  'color', 'dimension', 'typography', 'duration', 'easing', 'shadow', 'number',
])

const HEX_LITERAL = /#[0-9a-f]{3,8}\b/i

describe('single OKLCH design-system token SSOT (source.ts)', () => {
  it('every token name is a valid CSS custom-property ident', () => {
    const bad = ALL.filter((t) => !/^[a-z0-9_-]+$/i.test(t.name)).map((t) => t.name)
    expect(bad).toEqual([])
  })

  it('every token declares a known tier and kind', () => {
    const badTier = ALL.filter((t) => !VALID_TIERS.has(t.tier)).map((t) => `${t.name}:${t.tier}`)
    const badKind = ALL.filter((t) => !VALID_KINDS.has(t.kind)).map((t) => `${t.name}:${t.kind}`)
    expect(badTier).toEqual([])
    expect(badKind).toEqual([])
  })

  it('emits zero duplicate token names', () => {
    const counts = new Map<string, number>()
    for (const t of ALL) counts.set(t.name, (counts.get(t.name) ?? 0) + 1)
    const dupes = [...counts.entries()].filter(([, c]) => c > 1).map(([name]) => name)
    expect(dupes).toEqual([])
  })

  it('contains zero raw hex literals across raw, semantic, themes, and emitted tokens.generated.css', () => {
    const themeTokens = source.themes.flatMap((th) => th.tokens)
    const bad = [...ALL, ...themeTokens]
      .filter((tok) => HEX_LITERAL.test(tok.value))
      .map((tok) => `${tok.name}=${tok.value}`)
    expect(bad).toEqual([])

    const generated = readFileSync(resolve(process.cwd(), 'src/styles/tokens.generated.css'), 'utf8')
    expect(HEX_LITERAL.test(generated)).toBe(false)
  })

  it('pins the Tempered Slate dark, Warm Archival Paper light, and static High-Contrast presets', () => {
    const byName = new Map(ALL.map((tok) => [tok.name, tok.value]))
    expect(byName.get('bg-0')).toBe('oklch(0.145 0.005 70)')
    expect(byName.get('bg-4')).toBe('oklch(0.270 0.005 70)')
    expect(byName.get('cta-bg')).toBe('oklch(0.920 0.010 80)')
    expect(byName.get('focus')).toBe('oklch(0.720 0.110 245)')
    expect(byName.get('brass-1')).toBe('oklch(0.770 0.135 74)')
    expect(byName.get('warn')).toBe('oklch(0.830 0.150 95)')
    expect(byName.get('err-fg')).toBe('oklch(0.730 0.160 24)')

    const light = source.themes.find((th) => th.id === 'light')
    expect(light?.selector).toBe('[data-theme="light"]')
    expect(light?.tokens.find((tok) => tok.name === 'bg-0')?.value).toBe('oklch(0.975 0.005 75)')
    expect(light?.tokens.find((tok) => tok.name === 'fg-1')?.value).toBe('oklch(0.200 0.010 70)')

    const hcDark = source.themes.find((th) => th.id === 'high-contrast-dark')
    expect(hcDark?.selector).toBe(':root[data-contrast="high"]')
    expect(hcDark?.media).toBe('(prefers-contrast: more)')
  })

  it('defines the 4px spacing scale (+ --sp-0 hairline) and 44px mobile touch target', () => {
    const byName = new Map(ALL.map((tok) => [tok.name, tok.value]))
    expect(byName.get('sp-0')).toBe('2px')
    expect(byName.get('sp-1')).toBe('4px')
    expect(byName.get('sp-2')).toBe('8px')
    expect(byName.get('sp-3')).toBe('12px')
    expect(byName.get('sp-4')).toBe('16px')
    expect(byName.get('sp-5')).toBe('24px')
    expect(byName.get('sp-6')).toBe('32px')
    expect(byName.get('mobile-touch-target-min')).toBe('44px')
  })

  it('keeps zero off-grid spacing px literals across layout stylesheets', () => {
    const offGridRe = /\b(?:padding|margin|gap):\s*[^;]*\b(?:1|2|3|5|6|10)px\b/
    const sheets = ['shell.css', 'primitives.css', 'charts.css', 'chat.css', 'surfaces.css']
    const violations: string[] = []
    for (const sheet of sheets) {
      const text = readFileSync(resolve(process.cwd(), 'src/styles', sheet), 'utf8')
      const lines = text.split('\n')
      lines.forEach((line, idx) => {
        if (offGridRe.test(line)) violations.push(`${sheet}:${idx + 1}: ${line.trim()}`)
      })
    }
    expect(violations).toEqual([])
  })
})
