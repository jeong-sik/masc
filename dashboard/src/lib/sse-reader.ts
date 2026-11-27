import { batch } from '@preact/signals'

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
  const processLine = (curLine: string) => {
    if (curLine === '') {
      if (data.length > 0) {
        const payload = data.length === 1 ? data[0]! : data.join('\n')
        const ev = event || 'message'
        event = ''
        data = []
        onEvent(ev, payload)
      } else {
        event = ''
        data = []
      }
      return
    }
    if (curLine.charCodeAt(0) === 58) return
    const colon = curLine.indexOf(':')
    const key = colon < 0 ? curLine : curLine.slice(0, colon)
    if (key !== 'event' && key !== 'data') return
    const value = colon < 0
      ? ''
      : curLine.slice(colon + 1 < curLine.length && curLine.charCodeAt(colon + 1) === 32 ? colon + 2 : colon + 1)
    if (key === 'event') event = value
    else data.push(value)
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
      const len = text.length
      if (len > 0) {
        batch(() => {
          let pos = 0
          if (afterCR) {
            afterCR = false
            if (text.charCodeAt(0) === 10) pos = 1
          }
          if (text.indexOf('\r', pos) === -1) {
            while (pos < len) {
              const nl = text.indexOf('\n', pos)
              if (nl === -1) {
                line = line === '' ? text.slice(pos) : line + text.slice(pos)
                break
              }
              const segment = text.slice(pos, nl)
              if (line === '') {
                processLine(segment)
              } else {
                const full = line + segment
                line = ''
                processLine(full)
              }
              pos = nl + 1
            }
          } else {
            while (pos < len) {
              const nl = text.indexOf('\n', pos)
              const cr = text.indexOf('\r', pos)
              let brk: number
              let isCR = false
              if (cr !== -1 && (nl === -1 || cr < nl)) {
                brk = cr
                isCR = true
              } else if (nl !== -1) {
                brk = nl
              } else {
                line = line === '' ? text.slice(pos) : line + text.slice(pos)
                break
              }
              const segment = text.slice(pos, brk)
              if (line === '') {
                processLine(segment)
              } else {
                const full = line + segment
                line = ''
                processLine(full)
              }
              if (isCR) {
                if (brk + 1 < len) {
                  pos = text.charCodeAt(brk + 1) === 10 ? brk + 2 : brk + 1
                } else {
                  afterCR = true
                  pos = len
                }
              } else {
                pos = brk + 1
              }
            }
          }
        })
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
