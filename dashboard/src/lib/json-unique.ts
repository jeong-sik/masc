/** Parse JSON without silently replacing an earlier duplicate object member. */
export function parseUniqueJson(raw: string): unknown {
  const value: unknown = JSON.parse(raw)
  let offset = 0
  const whitespace = () => { while (offset < raw.length && ' \t\r\n'.includes(raw[offset]!)) offset++ }
  const readString = (): string => {
    const start = offset++
    while (offset < raw.length) {
      if (raw[offset] === '\\') offset += 2
      else if (raw[offset++] === '"') return JSON.parse(raw.slice(start, offset)) as string
    }
    throw new Error('unterminated JSON string')
  }
  const readValue = (): void => {
    whitespace()
    if (raw[offset] === '{') {
      offset++
      whitespace()
      const keys = new Set<string>()
      if (raw[offset] === '}') { offset++; return }
      for (;;) {
        whitespace()
        const key = readString()
        if (keys.has(key)) throw new Error('duplicate JSON member')
        keys.add(key)
        whitespace()
        offset++ // JSON.parse already verified the colon and syntax.
        readValue()
        whitespace()
        if (raw[offset++] === '}') return
      }
    }
    if (raw[offset] === '[') {
      offset++
      whitespace()
      if (raw[offset] === ']') { offset++; return }
      for (;;) {
        readValue()
        whitespace()
        if (raw[offset++] === ']') return
      }
    }
    if (raw[offset] === '"') { readString(); return }
    while (offset < raw.length && !',]} \t\r\n'.includes(raw[offset]!)) offset++
  }
  readValue()
  return value
}
