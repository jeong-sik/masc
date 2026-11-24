/**
 * MASC Dashboard Design System — Single OKLCH Token Codegen Driver
 *
 * Emits:
 *   1. dashboard/src/styles/tokens.generated.css (sole runtime CSS token SSOT + Tailwind v4 @theme)
 *   2. dashboard/design-system/source_styles/tokens.generated.css (preview mirror)
 *   3. dashboard/design-system/tokens/build/tokens.json (DTCG 2025.10)
 *
 * Run: pnpm --dir dashboard tokens:build
 */

import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { source, type TokenBase, type Theme } from './source.js'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = resolve(HERE, '..', '..', '..')

const OUT = {
  runtimeCss: resolve(REPO, 'dashboard/src/styles/tokens.generated.css'),
  previewCss: resolve(REPO, 'dashboard/design-system/source_styles/tokens.generated.css'),
  dtcgJson: resolve(REPO, 'dashboard/design-system/tokens/build/tokens.json'),
} as const

const HEADER = '/* @generated DO NOT EDIT — run `pnpm --dir dashboard tokens:build` (source: dashboard/design-system/tokens/source.ts) */\n\n'

function writeFile(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content, 'utf8')
  console.log(`  wrote ${path.replace(REPO + '/', '')}`)
}

const renderLine = (tok: TokenBase): string => `  --${tok.name}: ${tok.value};`

function renderThemeBlocks(): string {
  const parts: string[] = []
  for (const theme of source.themes) {
    const body = theme.tokens.map(renderLine).join('\n')
    parts.push(`${theme.selector} {\n  color-scheme: ${theme.mode};\n${body}\n}\n`)
    if (theme.media) {
      const mediaSel = theme.id === 'high-contrast-dark'
        ? ':root:not([data-theme="light"]):not([data-contrast="normal"])'
        : '[data-theme="light"]:not([data-contrast="normal"])'
      parts.push(`@media ${theme.media} {\n  ${mediaSel} {\n    color-scheme: ${theme.mode};\n${theme.tokens.map(tok => `    --${tok.name}: ${tok.value};`).join('\n')}\n  }\n}\n`)
    }
  }
  return parts.join('\n')
}

function buildRuntimeCss(): string {
  const all = [...source.raw, ...source.semantic]
  const rootBody = all.map(renderLine).join('\n')

  // Expose concise Tailwind v4 @theme bindings (avoid emitting duplicate alias families)
  const twLines: string[] = []
  const seenTw = new Set<string>()
  for (const tok of all) {
    if (tok.kind === 'color') {
      if (/^(kp\d|color-keeper-|k-\d+-(soft|border)|ok-|warn-|bad-|accent-|white-)/.test(tok.name)) continue
      const twName = tok.name.startsWith('color-') ? tok.name : `color-${tok.name}`
      if (seenTw.has(twName)) continue
      seenTw.add(twName)
      twLines.push(`  --${twName}: var(--${tok.name});`)
    } else if (tok.name.startsWith('font-size-')) {
      twLines.push(`  --text-${tok.name.slice('font-size-'.length)}: var(--${tok.name});`)
    } else if (tok.name.startsWith('radius-')) {
      twLines.push(`  --${tok.name}: var(--${tok.name});`)
    }
  }

  return [
    HEADER,
    `:root {\n  color-scheme: dark;\n${rootBody}\n}\n\n`,
    renderThemeBlocks(),
    `\n@theme inline {\n${twLines.join('\n')}\n}\n`,
  ].join('')
}

function buildPreviewCss(): string {
  const all = [...source.raw, ...source.semantic]
  return [
    HEADER,
    `:root {\n  color-scheme: dark;\n${all.map(renderLine).join('\n')}\n}\n\n`,
    renderThemeBlocks(),
  ].join('')
}

function dtcgKindToType(kind: TokenBase['kind']): string {
  switch (kind) {
    case 'color': return 'color'
    case 'dimension': return 'dimension'
    case 'duration': return 'duration'
    case 'easing': return 'cubicBezier'
    case 'shadow': return 'shadow'
    case 'typography': return 'fontFamily'
    case 'number': return 'number'
  }
}

function dtcgValue(tk: TokenBase): unknown {
  if (tk.kind !== 'easing') return tk.value
  const m = tk.value.trim().match(
    /^cubic-bezier\(\s*(-?\d*\.?\d+)\s*,\s*(-?\d*\.?\d+)\s*,\s*(-?\d*\.?\d+)\s*,\s*(-?\d*\.?\d+)\s*\)$/,
  )
  return m ? [Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4])] : tk.value
}

function buildDtcgJson(): string {
  const toGroup = (toks: ReadonlyArray<TokenBase>) => {
    const g: Record<string, unknown> = {}
    for (const tk of toks) {
      g[tk.name] = {
        $type: dtcgKindToType(tk.kind),
        $value: dtcgValue(tk),
        ...(tk.description ? { $description: tk.description } : {}),
      }
    }
    return g
  }
  const themes: Record<string, unknown> = {}
  for (const theme of source.themes as ReadonlyArray<Theme>) {
    themes[theme.id] = { $extensions: { mode: theme.mode }, ...toGroup(theme.tokens) }
  }
  return JSON.stringify({
    raw: toGroup(source.raw),
    semantic: toGroup(source.semantic),
    themes,
  }, null, 2) + '\n'
}

function main(): void {
  console.log('MASC OKLCH tokens codegen')
  writeFile(OUT.runtimeCss, buildRuntimeCss())
  writeFile(OUT.previewCss, buildPreviewCss())
  writeFile(OUT.dtcgJson, buildDtcgJson())
  console.log('done')
}

main()
