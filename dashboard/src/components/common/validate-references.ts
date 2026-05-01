// validate-references.ts — token reference integrity validation
//
// Kimi design system sec07 7.3.2: detect unused tokens and hardcoded colors.

import { findHardcodedColorsInFiles, type HardcodedColorMatch } from './find-hardcoded-colors'

export interface TokenReferenceReport {
  unused: string[]
  hardcoded: HardcodedColorMatch[]
  usageRate: number
}

export function validateTokenReferences(
  definedTokens: string[],
  sourceFiles: Array<{ path: string; content: string }>
): TokenReferenceReport {
  const usedTokens = new Set<string>()
  const definedSet = new Set(definedTokens)

  // Regex patterns to extract referenced token names from file content.
  // Using matchAll avoids the O(files × tokens) nested loop and prevents
  // substring false positives (e.g. token "color" matching "--color-bg").
  const VAR_USAGE_RE = /var\(--([a-zA-Z0-9_-]+)\)/g
  // Matches --token-name that is not part of a longer custom property name.
  const PROP_USAGE_RE = /(?<![a-zA-Z0-9_-])--([a-zA-Z0-9_-]+)(?![a-zA-Z0-9_-])/g

  for (const file of sourceFiles) {
    for (const [, name] of file.content.matchAll(VAR_USAGE_RE)) {
      if (definedSet.has(name)) usedTokens.add(name)
    }
    for (const [, name] of file.content.matchAll(PROP_USAGE_RE)) {
      if (definedSet.has(name)) usedTokens.add(name)
    }
  }

  const unused = definedTokens.filter((t) => !usedTokens.has(t))
  const hardcoded = findHardcodedColorsInFiles(sourceFiles)

  return {
    unused,
    hardcoded,
    usageRate: definedTokens.length > 0 ? usedTokens.size / definedTokens.length : 0,
  }
}
