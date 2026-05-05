import { authHeaders } from './core'

export interface KeeperShellStreamEvent {
  type: 'snapshot' | 'no_task' | 'error' | string
  keeper: string
  task_id?: string | null
  task_count?: number
  since_stdout?: number
  since_stderr?: number
  stdout_since?: string
  stderr_since?: string
  closed?: boolean
  status?: unknown
  bytes_dropped_stdout?: number
  bytes_dropped_stderr?: number
  message?: string
  generated_at?: number
}

function parseSseFrames(chunk: string): { frames: string[]; rest: string } {
  const normalized = chunk.replace(/\r\n/g, '\n')
  const frames: string[] = []
  let start = 0
  for (;;) {
    const split = normalized.indexOf('\n\n', start)
    if (split < 0) return { frames, rest: normalized.slice(start) }
    frames.push(normalized.slice(start, split))
    start = split + 2
  }
}

export function parseKeeperShellSseFrame(frame: string): KeeperShellStreamEvent | null {
  const dataLines = frame
    .split('\n')
    .filter(line => line.startsWith('data:'))
    .map(line => line.slice(5).trimStart())
  if (dataLines.length === 0) return null
  try {
    return JSON.parse(dataLines.join('\n')) as KeeperShellStreamEvent
  } catch {
    return null
  }
}

export async function streamKeeperShell(
  keeperName: string,
  {
    signal,
    onEvent,
  }: {
    signal?: AbortSignal
    onEvent: (event: KeeperShellStreamEvent) => void
  },
): Promise<void> {
  const keeper = keeperName.trim()
  if (!keeper) throw new Error('keeper name is required')
  const res = await fetch(`/api/dashboard/keeper-shell/${encodeURIComponent(keeper)}`, {
    headers: {
      ...authHeaders(),
      Accept: 'text/event-stream',
    },
    signal,
  })

  if (!res.ok) {
    const raw = await res.text()
    throw new Error(raw || `keeper shell stream failed (${res.status})`)
  }
  if (!res.body) throw new Error('keeper shell stream response body unavailable')

  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''

  try {
    for (;;) {
      const { done, value } = await reader.read()
      buffer += decoder.decode(value ?? new Uint8Array(), { stream: !done })
      const { frames, rest } = parseSseFrames(buffer)
      buffer = rest
      for (const frame of frames) {
        const event = parseKeeperShellSseFrame(frame)
        if (event) onEvent(event)
      }
      if (done) break
    }
    const tail = buffer.trim()
    if (tail) {
      const event = parseKeeperShellSseFrame(tail)
      if (event) onEvent(event)
    }
  } finally {
    reader.releaseLock()
  }
}
