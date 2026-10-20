import { Worker } from 'node:worker_threads'

// Conversion owns its worker through completion/abort. The caller captures the
// score and selected tracks before relinquishing the terminal to a child view.
export async function scoreDocument(snapshot, { signal } = {}) {
  signal?.throwIfAborted()
  const worker = new Worker(new URL('./worker.mjs', import.meta.url))
  let abort
  try {
    return await new Promise((resolve, reject) => {
      abort = () => reject(signal.reason)
      signal?.addEventListener('abort', abort, { once: true })
      worker.once('error', reject)
      worker.once('exit', code => reject(new Error(`Score conversion ended before returning a document (${code})`)))
      worker.once('message', message => {
        if (message.id !== 1 || typeof message.ok !== 'boolean') reject(new Error('Invalid score conversion response'))
        else if (!message.ok) reject(new Error(message.error))
        else resolve(message.result)
      })
      worker.postMessage({ id: 1, kind: 'source', source: snapshot.source, options: { tracks: snapshot.tracks } })
    })
  } finally {
    signal?.removeEventListener('abort', abort)
    await worker.terminate()
  }
}
