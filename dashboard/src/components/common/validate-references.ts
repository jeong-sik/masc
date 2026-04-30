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

  for (const file of sourceFiles) {
    for (const token of definedTokens) {
      if (
        file.content.includes(`var(--${token})`) ||
        file.content.includes(`--${token}`)
      ) {
        usedTokens.add(token)
      }
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
