import { parentPort, workerData } from 'node:worker_threads'
import { openMonitorSession } from './step-monitor-session.mjs'

let owner = null
const post = value => parentPort.postMessage({ ...value,
  diagnostics: owner ? { ...owner.diagnostics(), observedAt: new Date().toISOString() } : null })
const fail = error => owner?.cancel(error)
const receive = message => {
  try {
    switch (message.kind) {
      case 'send':
        owner.send({ messages: message.messages, held: new Map() })
          .then(() => post({ kind: 'sent' }), fail)
        break
      case 'inspect': post({ kind: 'diagnostics' }); break
      case 'stop': owner.stop(); break
      case 'cancel': fail(new Error(message.message)); break
      default: throw new Error('Invalid monitor worker request')
    }
  } catch (error) { fail(error) }
}
try {
  owner = openMonitorSession(workerData)
  parentPort.on('message', receive)
  parentPort.on('messageerror', fail)
  owner.ready.then(device => post({ kind: 'ready', device }), () => {})
  owner.clock.then(clock => post({ kind: 'clock', clock }), () => {})
  let device, error
  try { device = await owner.completion } catch (failure) { error = failure }
  post({ kind: 'terminal', device, error })
} catch (error) {
  owner?.cancel(error)
  await owner?.completion.catch(() => {})
  post({ kind: 'terminal', error })
} finally {
  parentPort.off('message', receive)
  parentPort.off('messageerror', fail)
  parentPort.close()
}
