import { describe, expect, it } from 'vitest'
import { ansi256ToCss, parseAnsiSgr, stripAnsi } from './ansi-sgr'

describe('ansi-sgr', () => {
  it('returns empty array for empty string and plain span for unstyled text', () => {
    expect(parseAnsiSgr('')).toEqual([])
    expect(parseAnsiSgr('hello world')).toEqual([{ text: 'hello world', style: {} }])
    expect(stripAnsi('hello world')).toBe('hello world')
  })

  it('parses standard 16 colors, bright colors, and resets', () => {
    const spans = parseAnsiSgr('\x1b[31mred\x1b[92mbright-green\x1b[0mplain\x1b[44mblue-bg\x1b[49mreset-bg')
    expect(spans).toHaveLength(5)
    expect(spans[0]!.text).toBe('red')
    expect(spans[0]!.style.fg).toBeTruthy()
    expect(spans[1]!.text).toBe('bright-green')
    expect(spans[1]!.style.fg).toBeTruthy()
    expect(spans[1]!.style.fg).not.toBe(spans[0]!.style.fg)
    expect(spans[2]).toEqual({ text: 'plain', style: {} })
    expect(spans[3]!.text).toBe('blue-bg')
    expect(spans[3]!.style.bg).toBeTruthy()
    expect(spans[4]).toEqual({ text: 'reset-bg', style: {} })
  })

  it('parses 256-color and truecolor sequences (semicolon and colon forms)', () => {
    const spans = parseAnsiSgr(
      '\x1b[38;5;196mcube\x1b[48;5;240mgray\x1b[38;2;12;34;56mrgb\x1b[48:2::200:100:50mcolon\x1b[mclear',
    )
    expect(spans[0]).toEqual({ text: 'cube', style: { fg: ansi256ToCss(196) } })
    expect(spans[1]).toEqual({ text: 'gray', style: { fg: ansi256ToCss(196), bg: ansi256ToCss(240) } })
    expect(spans[2]).toEqual({ text: 'rgb', style: { fg: 'rgb(12, 34, 56)', bg: ansi256ToCss(240) } })
    expect(spans[3]).toEqual({ text: 'colon', style: { fg: 'rgb(12, 34, 56)', bg: 'rgb(200, 100, 50)' } })
    expect(spans[4]).toEqual({ text: 'clear', style: {} })
  })

  it('parses bold, dim, italic, underline and selective resets', () => {
    const spans = parseAnsiSgr('\x1b[1;3;4mstyled\x1b[22mnot-bold\x1b[23;24mplain')
    expect(spans[0]).toEqual({
      text: 'styled',
      style: { bold: true, italic: true, underline: true },
    })
    expect(spans[1]).toEqual({
      text: 'not-bold',
      style: { italic: true, underline: true },
    })
    expect(spans[2]).toEqual({ text: 'plain', style: {} })
  })

  it('strips non-SGR CSI and OSC sequences safely while preserving literal HTML text', () => {
    const input = '\x1b]0;Window Title\x07\x1b[2K\x1b[1G\x1b[32m<script>alert(1)</script>\x1b[0m'
    const spans = parseAnsiSgr(input)
    expect(spans).toHaveLength(1)
    expect(spans[0]!.text).toBe('<script>alert(1)</script>')
    expect(spans[0]!.style.fg).toBeTruthy()
    expect(stripAnsi(input)).toBe('<script>alert(1)</script>')
  })
})
