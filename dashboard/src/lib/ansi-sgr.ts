/**
 * Pure, XSS-safe ANSI SGR escape sequence parser.
 *
 * Converts ANSI SGR sequences (`\x1b[...m`) into typed `AnsiSpan[]` segments
 * intended to be rendered as Preact text nodes (never `dangerouslySetInnerHTML`).
 * Strips non-SGR CSI/OSC/ESC control sequences safely.
 */

export interface AnsiStyle {
  readonly fg?: string
  readonly bg?: string
  readonly bold?: boolean
  readonly dim?: boolean
  readonly italic?: boolean
  readonly underline?: boolean
}

export interface AnsiSpan {
  readonly text: string
  readonly style: AnsiStyle
}

// Standard 16 ANSI colors tuned for high readability on dark terminal surfaces.
const ANSI_16_PALETTE: readonly string[] = [
  '#1e222a', // 0 black
  '#e06c75', // 1 red
  '#98c379', // 2 green
  '#e5c07b', // 3 yellow
  '#61afef', // 4 blue
  '#c678dd', // 5 magenta
  '#56b6c2', // 6 cyan
  '#abb2bf', // 7 white
  '#5c6370', // 8 bright black (gray)
  '#f48771', // 9 bright red
  '#b5e890', // 10 bright green
  '#f2d48f', // 11 bright yellow
  '#82c6ff', // 12 bright blue
  '#dda0f5', // 13 bright magenta
  '#7ad5e0', // 14 bright cyan
  '#f0f4f8', // 15 bright white
]

function clampByte(n: number): number {
  if (!Number.isFinite(n)) return 0
  return Math.max(0, Math.min(255, Math.round(n)))
}

export function ansi256ToCss(index: number): string {
  const n = clampByte(index)
  if (n < 16) return ANSI_16_PALETTE[n]!
  if (n < 232) {
    const idx = n - 16
    const r = Math.floor(idx / 36)
    const g = Math.floor((idx % 36) / 6)
    const b = idx % 6
    const toChannel = (v: number) => (v === 0 ? 0 : 55 + v * 40)
    return `rgb(${toChannel(r)}, ${toChannel(g)}, ${toChannel(b)})`
  }
  const gray = 8 + (n - 232) * 10
  return `rgb(${gray}, ${gray}, ${gray})`
}

interface MutableStyle {
  fg?: string
  bg?: string
  bold?: boolean
  dim?: boolean
  italic?: boolean
  underline?: boolean
}

function freezeStyle(s: MutableStyle): AnsiStyle {
  const out: MutableStyle = {}
  if (s.fg !== undefined) out.fg = s.fg
  if (s.bg !== undefined) out.bg = s.bg
  if (s.bold) out.bold = true
  if (s.dim) out.dim = true
  if (s.italic) out.italic = true
  if (s.underline) out.underline = true
  return out
}

function stylesEqual(a: AnsiStyle, b: AnsiStyle): boolean {
  return (
    a.fg === b.fg
    && a.bg === b.bg
    && Boolean(a.bold) === Boolean(b.bold)
    && Boolean(a.dim) === Boolean(b.dim)
    && Boolean(a.italic) === Boolean(b.italic)
    && Boolean(a.underline) === Boolean(b.underline)
  )
}

function applyExtendedColor(
  parts: readonly number[],
  startIdx: number,
  target: 'fg' | 'bg',
  state: MutableStyle,
): number {
  const mode = parts[startIdx + 1]
  if (mode === 5 && startIdx + 2 < parts.length) {
    const color = ansi256ToCss(parts[startIdx + 2]!)
    if (target === 'fg') state.fg = color
    else state.bg = color
    return startIdx + 2
  }
  if (mode === 2 && startIdx + 4 < parts.length) {
    const r = clampByte(parts[startIdx + 2]!)
    const g = clampByte(parts[startIdx + 3]!)
    const b = clampByte(parts[startIdx + 4]!)
    const color = `rgb(${r}, ${g}, ${b})`
    if (target === 'fg') state.fg = color
    else state.bg = color
    return startIdx + 4
  }
  return startIdx
}

function applySgrParams(rawParams: string, state: MutableStyle): void {
  if (rawParams.length === 0) {
    state.fg = undefined
    state.bg = undefined
    state.bold = undefined
    state.dim = undefined
    state.italic = undefined
    state.underline = undefined
    return
  }

  // Normalize colon subparameters (e.g. `38:2::255:0:0` or `38:5:196`) while
  // supporting standard semicolon-separated SGR codes.
  const tokens = rawParams.split(';')
  const codes: number[] = []
  for (const tok of tokens) {
    if (tok.includes(':')) {
      const sub = tok.split(':')
      const first = Number(sub[0])
      if ((first === 38 || first === 48) && sub[1] === '5' && sub.length >= 3) {
        codes.push(first, 5, Number(sub[2]))
      } else if ((first === 38 || first === 48) && sub[1] === '2') {
        // Handle both `38:2:R:G:B` (5 parts) and ITU `38:2:CS:R:G:B` (6+ parts)
        if (sub.length >= 6) {
          codes.push(first, 2, Number(sub[3]), Number(sub[4]), Number(sub[5]))
        } else if (sub.length >= 5) {
          codes.push(first, 2, Number(sub[2]), Number(sub[3]), Number(sub[4]))
        }
      } else if (Number.isFinite(first)) {
        codes.push(first)
      }
      continue
    }
    if (tok === '') {
      codes.push(0)
    } else {
      const parsed = Number(tok)
      if (Number.isFinite(parsed)) codes.push(parsed)
    }
  }

  for (let i = 0; i < codes.length; i += 1) {
    const code = codes[i]!
    if (code === 0) {
      state.fg = undefined
      state.bg = undefined
      state.bold = undefined
      state.dim = undefined
      state.italic = undefined
      state.underline = undefined
    } else if (code === 1) {
      state.bold = true
    } else if (code === 2) {
      state.dim = true
    } else if (code === 3) {
      state.italic = true
    } else if (code === 4) {
      state.underline = true
    } else if (code === 22) {
      state.bold = undefined
      state.dim = undefined
    } else if (code === 23) {
      state.italic = undefined
    } else if (code === 24) {
      state.underline = undefined
    } else if (code >= 30 && code <= 37) {
      state.fg = ANSI_16_PALETTE[code - 30]
    } else if (code === 38) {
      i = applyExtendedColor(codes, i, 'fg', state)
    } else if (code === 39) {
      state.fg = undefined
    } else if (code >= 40 && code <= 47) {
      state.bg = ANSI_16_PALETTE[code - 40]
    } else if (code === 48) {
      i = applyExtendedColor(codes, i, 'bg', state)
    } else if (code === 49) {
      state.bg = undefined
    } else if (code >= 90 && code <= 97) {
      state.fg = ANSI_16_PALETTE[8 + (code - 90)]
    } else if (code >= 100 && code <= 107) {
      state.bg = ANSI_16_PALETTE[8 + (code - 100)]
    }
  }
}

// Matches:
// 1. CSI sequences: `\x1b[` + parameter bytes + intermediate bytes + final byte
// 2. OSC sequences: `\x1b]` ... terminated by BEL (`\x07`) or ST (`\x1b\\`)
// 3. DCS/SOS/PM/APC sequences terminated by ST (`\x1b\\`)
// 4. 2-byte ESC sequences
const ANSI_TOKEN_RE =
  // eslint-disable-next-line no-control-regex
  /\x1b\[([0-9:;?]*)([ -/]*)([@-~])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b[PX^_][^\x1b]*(?:\x1b\\)?|\x1b[@-Z\\-_]/g

function pushSpan(spans: AnsiSpan[], text: string, style: AnsiStyle): void {
  if (text.length === 0) return
  const prev = spans.length > 0 ? spans[spans.length - 1] : null
  if (prev && stylesEqual(prev.style, style)) {
    spans[spans.length - 1] = { text: prev.text + text, style: prev.style }
  } else {
    spans.push({ text, style })
  }
}

export function parseAnsiSgr(text: string): AnsiSpan[] {
  if (text.length === 0) return []
  const spans: AnsiSpan[] = []
  const state: MutableStyle = {}
  let lastIndex = 0

  ANSI_TOKEN_RE.lastIndex = 0
  let match: RegExpExecArray | null
  while ((match = ANSI_TOKEN_RE.exec(text)) !== null) {
    if (match.index > lastIndex) {
      pushSpan(spans, text.slice(lastIndex, match.index), freezeStyle(state))
    }
    const csiParams = match[1]
    const csiIntermediate = match[2]
    const csiFinal = match[3]
    if (csiFinal === 'm' && csiIntermediate === '' && csiParams !== undefined && !csiParams.includes('?')) {
      applySgrParams(csiParams, state)
    }
    // Non-SGR CSI/OSC/ESC sequences are intentionally stripped.
    lastIndex = match.index + match[0].length
  }

  if (lastIndex < text.length) {
    pushSpan(spans, text.slice(lastIndex), freezeStyle(state))
  }
  return spans
}

export function stripAnsi(text: string): string {
  if (text.length === 0) return ''
  ANSI_TOKEN_RE.lastIndex = 0
  return text.replace(ANSI_TOKEN_RE, '')
}
