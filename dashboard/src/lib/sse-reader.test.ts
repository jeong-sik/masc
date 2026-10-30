import { describe, expect, it } from 'vitest'
import { readSse } from './sse-reader'
const chunks = (values: Uint8Array[]) => new ReadableStream<Uint8Array>({ start(controller) { values.forEach(value => controller.enqueue(value)); controller.close() } })
describe('authenticated SSE framing', () => {
  it('preserves fragmented UTF-8, CRLF, multiline data and comments', async () => {
    const bytes = new TextEncoder().encode(': ping\r\nevent: draft\r\ndata: 한글 😀\r\ndata:  indented\r\n\r\nevent: ignored\ndata: next\n\n')
    const events: unknown[] = []
    await readSse(chunks(Array.from(bytes, byte => Uint8Array.of(byte))), (event, data) => events.push({ event, data }))
    expect(events).toEqual([{ event: 'draft', data: '한글 😀\n indented' }, { event: 'ignored', data: 'next' }])
  })
  it('discards truncated frames and rejects invalid UTF-8', async () => {
    const events: string[] = []
    await readSse(chunks([new TextEncoder().encode('data: incomplete\n')]), (_, data) => events.push(data))
    expect(events).toEqual([])
    await expect(readSse(chunks([Uint8Array.of(0xff)]), () => {})).rejects.toThrow()
  })
  it('cancels the body after failed event validation', async () => {
    let cancelled = false
    const body = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(new TextEncoder().encode('data: bad\n\n')) }, cancel() { cancelled = true } })
    await expect(readSse(body, () => { throw new Error('wrong document') })).rejects.toThrow('wrong document')
    expect(cancelled).toBe(true)
  })
})
