// Fetch streams accept headers; EventSource would put private credentials in
// URLs. Parse lines across arbitrary UTF-8 chunks, including split CRLF pairs.
export async function readSse(
  body: ReadableStream<Uint8Array>,
  onEvent: (event: string, data: string) => void,
  options: { idleTimeoutMs?: number; onActivity?: () => void; signal?: AbortSignal } = {},
): Promise<void> {
  const reader = body.getReader(), decoder = new TextDecoder('utf-8', { fatal: true })
  const abort = () => { void reader.cancel().catch(() => {}) }
  options.signal?.addEventListener('abort', abort, { once: true })
  if (options.signal?.aborted) abort()
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
  const read = async (): Promise<ReadableStreamReadResult<Uint8Array>> => {
    if (options.idleTimeoutMs === undefined) return reader.read()
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      return await Promise.race([
        reader.read(),
        new Promise<never>((_resolve, reject) => {
          timer = setTimeout(() => reject(new Error('observer stream idle timeout')), options.idleTimeoutMs)
        }),
      ])
    } finally {
      if (timer !== undefined) clearTimeout(timer)
    }
  }
  try {
    while (true) {
      if (options.signal?.aborted) throw new DOMException('Observer stopped', 'AbortError')
      const chunk = await read()
      if (options.signal?.aborted) throw new DOMException('Observer stopped', 'AbortError')
      if (chunk.value?.length) options.onActivity?.()
      const text = decoder.decode(chunk.value, { stream: !chunk.done })
      for (const char of text) {
        if (afterCR && char === '\n') { afterCR = false; continue }
        afterCR = false
        if (char === '\r' || char === '\n') { endLine(); afterCR = char === '\r' }
        else line += char
      }
      if (chunk.done) return
    }
  } finally {
    options.signal?.removeEventListener('abort', abort)
    // A stalled source must not keep the caller from reporting an idle or
    // invalid stream while the underlying transport is being cancelled.
    void reader.cancel().catch(() => {})
    reader.releaseLock()
  }
}
