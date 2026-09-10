// Each opened comparison owns its worker. Closing, changing the receipt or
// unmounting terminates the actual computation, including synchronous diff work.
export function editSnapshotDiff(before: string, after: string, signal: AbortSignal): Promise<string> {
  if (signal.aborted) return Promise.reject(signal.reason)
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL('./edit-snapshot-diff.worker.ts', import.meta.url), { type: 'module' })
    const cleanup = () => {
      signal.removeEventListener('abort', abort)
      worker.terminate()
    }
    const abort = () => { cleanup(); reject(signal.reason) }
    signal.addEventListener('abort', abort, { once: true })
    worker.onmessage = (event: MessageEvent<unknown>) => {
      cleanup()
      if (typeof event.data === 'string') resolve(event.data)
      else reject(new Error('편집 diff 응답이 올바르지 않습니다.'))
    }
    worker.onerror = (event: ErrorEvent) => {
      cleanup()
      reject(new Error(event.message || '편집 diff 계산에 실패했습니다.'))
    }
    worker.onmessageerror = () => {
      cleanup()
      reject(new Error('편집 diff 응답을 읽을 수 없습니다.'))
    }
    try { worker.postMessage({ before, after }) } catch (error) { cleanup(); reject(error) }
  })
}
