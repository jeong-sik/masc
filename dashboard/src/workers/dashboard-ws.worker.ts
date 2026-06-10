import { parseIncomingPayloads } from '../dashboard-ws-parse'

self.onmessage = (event: MessageEvent<{ id: number; data: string }>) => {
  const { id, data } = event.data
  const payloads = parseIncomingPayloads(data)
  self.postMessage({ id, payloads })
}
