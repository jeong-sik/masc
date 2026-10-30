// Fetch streams accept headers; EventSource would put private credentials in
// URLs. Parse lines across arbitrary UTF-8 chunks, including split CRLF pairs.
export async function readSse(body: ReadableStream<Uint8Array>, onEvent: (event: string, data: string) => void): Promise<void> {
  const reader = body.getReader(), decoder = new TextDecoder('utf-8', { fatal: true })
  let line = '', event = '', data: string[] = [], afterCR = false
  const endLine = () => {
    if (line === '') {
      if (data.length) onEvent(event || 'message', data.join('\n'))
      event = ''; data = []
    } else if (!line.startsWith(':')) {
      const colon = line.indexOf(':')
      const key = colon < 0 ? line : line.slice(0, colon)
      const raw = colon < 0 ? '' : line.slice(colon + 1)
      const value = raw.startsWith(' ') ? raw.slice(1) : raw
      if (key === 'event') event = value
      if (key === 'data') data.push(value)
    }
    line = ''
  }
  try {
    while (true) {
      const chunk = await reader.read()
      const text = decoder.decode(chunk.value, { stream: !chunk.done })
      for (const char of text) {
        if (afterCR && char === '\n') { afterCR = false; continue }
        afterCR = false
        if (char === '\r' || char === '\n') { endLine(); afterCR = char === '\r' }
        else line += char
      }
      if (chunk.done) return
    }
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock() }
}
