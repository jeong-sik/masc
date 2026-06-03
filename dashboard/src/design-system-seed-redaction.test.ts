import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

import { describe, expect, it } from 'vitest'

const roots = [
  'design-system',
]

const searchableExtensions = new Set(['.html', '.js', '.jsx', '.md'])

const bannedPatterns = [
  { name: 'embedded masc dump marker', pattern: /AUTO-GENERATED from \.masc|\.masc \(redacted|source["']?\s*:\s*["']\.masc/i },
  { name: 'real masc mirror claim', pattern: /mirrors real \.masc|sourced from real \.masc|real values from .*\.json/i },
  { name: 'old anonymized provider placeholder', pattern: /\bprovider-[adfk]\b/i },
  { name: 'old provider backend placeholder', pattern: /\b(?:backend|api)_provider_[adfk]\b/i },
  { name: 'old cli tool placeholder', pattern: /\bcli-tool-[a-z]\b/i },
  { name: 'old agent/model placeholder', pattern: /\bagent-llm|\bmodel-[a-z][a-z0-9-]*/i },
  { name: 'old strict runtime id', pattern: /\btool_use_strict\b/i },
  { name: 'provider reasoning signature detail', pattern: /\b(?:thoughtSignature|redacted_thinking|reasoning_content|reasoning_details)\b/i },
] as const

function extensionOf(path: string): string {
  const dot = path.lastIndexOf('.')
  return dot >= 0 ? path.slice(dot) : ''
}

function collectFiles(path: string): string[] {
  const status = statSync(path)
  if (status.isFile()) {
    return searchableExtensions.has(extensionOf(path)) ? [path] : []
  }
  if (!status.isDirectory()) return []

  return readdirSync(path)
    .flatMap((entry) => collectFiles(join(path, entry)))
}

describe('design-system preview seed redaction', () => {
  it('does not reintroduce live .masc dumps or provider-wire placeholders', () => {
    const files = roots.flatMap(collectFiles)
    const violations: string[] = []

    for (const file of files) {
      const source = readFileSync(file, 'utf8')
      for (const banned of bannedPatterns) {
        if (banned.pattern.test(source)) {
          violations.push(`${relative(process.cwd(), file)}: ${banned.name}`)
        }
      }
    }

    expect(violations).toEqual([])
  })
})
