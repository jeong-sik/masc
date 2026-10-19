import { parentPort, workerData } from 'node:worker_threads'
import { readMusicInfo } from './music-library-info.mjs'

try { parentPort.postMessage({ ok: true, info: await readMusicInfo(workerData) }) }
catch (error) { parentPort.postMessage({ ok: false, error: error.message }) }
finally { parentPort.close() }
