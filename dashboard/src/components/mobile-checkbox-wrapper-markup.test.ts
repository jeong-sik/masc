import { readFileSync, readdirSync } from 'node:fs'
import { join, relative, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

const ROOT = resolve(__dirname)

function productionTypescriptFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) return productionTypescriptFiles(path)
    if (!entry.name.endsWith('.ts') || entry.name.endsWith('.test.ts')) return []
    return [path]
  })
}

describe('mobile checkbox wrapper markup', () => {
  it('opts every clickable checkbox label into the runtime target contract', () => {
    const violations: string[] = []

    for (const file of productionTypescriptFiles(ROOT)) {
      if (file.endsWith('/common/checkbox.ts')) continue
      const source = readFileSync(file, 'utf8')
      const labels = [...source.matchAll(/<label\b[\s\S]*?<\/label>/g)]
      const semanticRanges = labels
        .filter(match => /(?:<\$\{Checkbox\}|type="checkbox")/.test(match[0]))
        .filter(match => match[0].includes('v2-mobile-operator-target'))
        .map(match => [match.index, match.index + match[0].length] as const)

      for (const match of source.matchAll(/<\$\{Checkbox\}|type="checkbox"/g)) {
        const index = match.index
        if (semanticRanges.some(([start, end]) => index >= start && index < end)) continue
        const isSetupGuideAssociation = file.endsWith('/setup-guide-card.ts')
          && source.includes('for=${`setup-step-${connectorId}-${idx}`}')
          && source.includes('class=${`v2-mobile-operator-target min-w-0 flex-1 cursor-pointer')
        if (!isSetupGuideAssociation) {
          violations.push(`${relative(ROOT, file)}:${index}`)
        }
      }
    }

    expect(violations).toEqual([])
  })
})
