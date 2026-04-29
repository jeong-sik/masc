/**
 * Dashboard WebSocket message parsing — extracted so it can run in a
 * Web Worker without pulling in the main-thread signal graph.
 */

export function parseWebSocketSseFrames(data: string): unknown[] {
  const payloads: unknown[] = []
  const frames = data.split(/\r?\n\r?\n/)
  for (const frame of frames) {
    const dataLines: string[] = []
    for (const line of frame.split(/\r?\n/)) {
      if (!line.startsWith('data:')) continue
      const value = line.slice('data:'.length)
      dataLines.push(value.startsWith(' ') ? value.slice(1) : value)
    }
    if (dataLines.length === 0) continue
    const body = dataLines.join('\n').trim()
    if (!body || body === '[DONE]') continue
    try {
      payloads.push(JSON.parse(body))
    } catch (err) {
      const sample = body.length > 200 ? `${body.slice(0, 200)}…(${body.length} bytes total)` : body
      // eslint-disable-next-line no-console
      console.warn('[dashboard-ws] non-JSON SSE frame dropped', { sample, err })
    }
  }
  return payloads
}

export function parseIncomingPayloads(data: string): unknown[] {
  try {
    return [JSON.parse(data)]
  } catch {
    return parseWebSocketSseFrames(data)
  }
}
