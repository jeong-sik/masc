// validate-contrast.ts — token contrast validation (ΔE check)
//
// Kimi design system sec07 7.3.1: OkLCH-based color contrast validation.

import { oklch, differenceEuclidean } from 'culori'

export interface ContrastViolation {
  tokenA: string
  tokenB: string
  contrast: number
  required: number
}

export function validateTokenContrast(
  tokens: Record<string, string>,
  requiredDelta: number = 0.5
): ContrastViolation[] {
  const violations: ContrastViolation[] = []
  const entries = Object.entries(tokens)

  for (let i = 0; i < entries.length; i++) {
    for (let j = i + 1; j < entries.length; j++) {
      const entryA = entries[i]
      const entryB = entries[j]
      if (!entryA || !entryB) continue
      const [nameA, valueA] = entryA
      const [nameB, valueB] = entryB

      const colorA = oklch(valueA)
      const colorB = oklch(valueB)
      if (!colorA || !colorB) continue

      const deltaE = differenceEuclidean('oklch')(colorA, colorB)
      if (deltaE < requiredDelta) {
        violations.push({
          tokenA: nameA,
          tokenB: nameB,
          contrast: deltaE,
          required: requiredDelta,
        })
      }
    }
  }
  return violations
}
