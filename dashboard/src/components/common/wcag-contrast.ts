// wcag-contrast.ts — WCAG 2.2 relative luminance contrast validation
//
// Kimi design system sec07 7.3.1: WCAG AA/AAA contrast ratio automatic
// calculation. Complements OkLCH ΔE validation (validate-contrast.ts)
// with perceptually-uniform luminance-based ratios required by WCAG.

export interface WCAGViolation {
  tokenA: string
  tokenB: string
  ratio: number
  required: number
  level: 'AA' | 'AAA'
}

function hexToRgb(hex: string): { r: number; g: number; b: number } | null {
  const normalized = hex.trim().toLowerCase()
  const m = normalized.match(/^#([0-9a-f]{3,8})$/)
  if (!m) return null

  const digits = m[1]
  if (digits.length === 3) {
    const [r, g, b] = [0, 1, 2].map((i) =>
      parseInt(digits[i].repeat(2), 16)
    )
    return { r, g, b }
  }
  if (digits.length === 6) {
    const r = parseInt(digits.slice(0, 2), 16)
    const g = parseInt(digits.slice(2, 4), 16)
    const b = parseInt(digits.slice(4, 6), 16)
    return { r, g, b }
  }
  if (digits.length === 8) {
    const r = parseInt(digits.slice(0, 2), 16)
    const g = parseInt(digits.slice(2, 4), 16)
    const b = parseInt(digits.slice(4, 6), 16)
    return { r, g, b }
  }
  return null
}

function channelToLinear(c: number): number {
  const s = c / 255
  return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4)
}

/** Relative luminance of a color per WCAG 2.2 definition. */
export function relativeLuminance(hex: string): number | null {
  const rgb = hexToRgb(hex)
  if (!rgb) return null
  const r = channelToLinear(rgb.r)
  const g = channelToLinear(rgb.g)
  const b = channelToLinear(rgb.b)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

/** Contrast ratio between two colors (1:1 to 21:1). */
export function contrastRatio(a: string, b: string): number | null {
  const l1 = relativeLuminance(a)
  const l2 = relativeLuminance(b)
  if (l1 == null || l2 == null) return null
  const lighter = Math.max(l1, l2)
  const darker = Math.min(l1, l2)
  return (lighter + 0.05) / (darker + 0.05)
}

/** Minimum required ratio for the given WCAG level and text size. */
export function requiredRatio(
  level: 'AA' | 'AAA',
  largeText = false
): number {
  if (level === 'AAA') return largeText ? 4.5 : 7
  return largeText ? 3 : 4.5
}

/** Validate all color pairs in a token map against WCAG thresholds. */
export function validateWCAGContrast(
  tokens: Record<string, string>,
  level: 'AA' | 'AAA' = 'AA',
  largeText = false
): WCAGViolation[] {
  const violations: WCAGViolation[] = []
  const entries = Object.entries(tokens)
  const req = requiredRatio(level, largeText)

  for (let i = 0; i < entries.length; i++) {
    for (let j = i + 1; j < entries.length; j++) {
      const [nameA, valueA] = entries[i]
      const [nameB, valueB] = entries[j]

      const ratio = contrastRatio(valueA, valueB)
      if (ratio == null) continue
      if (ratio < req) {
        violations.push({
          tokenA: nameA,
          tokenB: nameB,
          ratio,
          required: req,
          level,
        })
      }
    }
  }
  return violations
}
