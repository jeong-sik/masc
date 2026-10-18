import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdtemp, readFile, rm, access } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { newProject, editProject, PPQ } from '../sequencer-project.mjs'
import { projectMidiTimeline } from '../sequencer-midi.mjs'

test('the actual preparation worker writes MIDI without a SoundFont and refuses cancelled work', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'masc-midi-worker-'))
  const worker = new Worker(new URL('../sequencer-worker.mjs', import.meta.url))
  const project = editProject(newProject(), 'track-1', { kind: 'note', pitch: 60, start: 0, duration: PPQ, velocity: 96 })
  const cancel = new Int32Array(new SharedArrayBuffer(4))
  async function job(id) {
    const result = once(worker, 'message')
    worker.postMessage({ id, path: join(directory, `${id}.json`), project, cancel: cancel.buffer,
      options: { format: 'midi', soundfontPath: join(directory, 'nonexistent.sf2') } })
    return (await result)[0]
  }
  try {
    const result = await job(1)
    assert.equal(result.ok, true)
    assert.deepEqual(JSON.parse(await readFile(result.result.path, 'utf8')), projectMidiTimeline(project))
    Atomics.store(cancel, 0, 1)
    assert.equal((await job(2)).ok, false)
    await assert.rejects(access(join(directory, '2.json')), { code: 'ENOENT' })
  } finally { await worker.terminate(); await rm(directory, { recursive: true, force: true }) }
})
