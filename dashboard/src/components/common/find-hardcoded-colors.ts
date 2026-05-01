// find-hardcoded-colors.ts — hardcoded color detection
//
// Kimi design system sec07 7.3.2: detect literal hex colors in source strings.

export interface HardcodedColorMatch {
  file: string
  color: string
  line: number
}

// Valid CSS hex color lengths are 3 (#RGB), 4 (#RGBA), 6 (#RRGGBB), 8 (#RRGGBBAA).
// Lengths 5 and 7 are not valid CSS and would be false positives.
// The negative lookahead ensures we don't partially match longer sequences.
const HEX_COLOR_REGEX = /#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})(?![0-9a-fA-F])/g
const ALLOWED_COLORS = new Set(['transparent', 'inherit', 'currentColor', 'none'])

export function findHardcodedColorsInContent(
  filePath: string,
  content: string
): HardcodedColorMatch[] {
  const results: HardcodedColorMatch[] = []
  const lines = content.split('\n')
  lines.forEach((line, idx) => {
    const matches = line.match(HEX_COLOR_REGEX)
    if (matches) {
      matches.forEach((color) => {
        if (!ALLOWED_COLORS.has(color.toLowerCase())) {
          results.push({ file: filePath, color, line: idx + 1 })
        }
      })
    }
  })
  return results
}

export function findHardcodedColorsInFiles(
  files: Array<{ path: string; content: string }>
): HardcodedColorMatch[] {
  return files.flatMap((f) => findHardcodedColorsInContent(f.path, f.content))
}
