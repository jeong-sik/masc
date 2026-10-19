import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { MusicWorkbench, musicLibrary } from '../music-workbench.mjs'
import { saveProject, loadProject } from '../sequencer-files.mjs'
import { newProject, editProject, PPQ } from '../sequencer-project.mjs'

const temporary = async action => {
  const root = await mkdtemp(join(tmpdir(), 'masc-music-home-'))
  try { await action(root) } finally { await rm(root, { recursive: true, force: true }) }
}
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done }); return { promise, resolve } }
const flush = () => new Promise(resolve => setImmediate(resolve))

test('library retains real project identities and partial read errors independently', async () => {
  await temporary(async root => {
    const projectRoot = join(root, 'projects'), sessionRoot = join(root, 'takes')
    await mkdir(projectRoot); await writeFile(sessionRoot, 'not a directory')
    const path = join(projectRoot, '한 곡.json')
    await saveProject(path, newProject()); await writeFile(join(projectRoot, 'readme.txt'), 'not a project')
    const library = await musicLibrary({ projectRoot, sessionRoot })
    assert.deepEqual(library.entries.filter(entry => entry.kind === 'project').map(entry => entry.path), [path])
    assert.equal(library.errors.length, 1)
    assert.equal(library.errors[0].root, sessionRoot)
    assert.equal(library.entries.some(entry => entry.kind === 'recording'), true)
    await rm(sessionRoot); await mkdir(sessionRoot); await mkdir(join(sessionRoot, 'take-1'))
    const refreshed = await musicLibrary({ projectRoot, sessionRoot })
    assert.deepEqual(refreshed.entries.filter(entry => entry.kind === 'session').map(entry => entry.path), [join(sessionRoot, 'take-1')])
    assert.deepEqual(refreshed.errors, [])
  })
})

test('returning from a phrase re-discovers its saved document and forwards the exact child options', async () => {
  await temporary(async root => {
    const requests = [], projectRoot = join(root, 'projects'), sessionRoot = join(root, 'takes')
    const path = join(projectRoot, 'phrase.json'), stateDirectory = join(root, 'vst')
    const model = new MusicWorkbench({ projectRoot, sessionRoot, stateDirectory, output: 'chosen-UID',
      open: async (entry, options) => {
        requests.push({ entry, options })
        await saveProject(path, editProject(newProject(), 'track-1', { kind: 'note', pitch: 60, start: 0, duration: PPQ, velocity: 96 }))
      } })
    await model.refresh(); await model.activate()
    assert.equal(requests.length, 1)
    assert.equal(requests[0].entry.kind, 'phrase')
    assert.equal(requests[0].options.embedded, true)
    assert.equal(requests[0].options.output, 'chosen-UID')
    assert.equal(requests[0].options.stateDirectory, stateDirectory)
    assert.equal(requests[0].options.sessionRoot, sessionRoot)
    assert.equal(model.entries.some(entry => entry.path === path), true)
    assert.equal((await loadProject(path)).project.tracks[0].notes[0].pitch, 60)
    await model.close()
  })
})

test('close cancels one admitted child and waits for cleanup without admitting another', async () => {
  const finished = deferred(); let requests = 0, signal
  const model = new MusicWorkbench({ open: async (_entry, options) => { requests++; signal = options.signal; await finished.promise } })
  model.activate(); await flush()
  model.activate({ kind: 'arrangement' })
  let returned = false
  const closing = model.close().then(() => { returned = true })
  await flush()
  assert.equal(signal.aborted, true); assert.equal(returned, false); assert.equal(requests, 1)
  model.activate({ kind: 'recording' }); assert.equal(requests, 1)
  finished.resolve(); await closing
  assert.equal(model.child, null)
})

test('a retired library read cannot overwrite the refreshed library or close state', async () => {
  const reads = []
  const model = new MusicWorkbench({ read: (_roots, options) => {
    const pending = deferred(); reads.push({ ...pending, signal: options.signal }); return pending.promise
  } })
  const old = model.refresh(); await flush()
  const current = model.refresh(); await flush()
  assert.equal(reads[0].signal.aborted, true)
  reads[1].resolve({ entries: [{ kind: 'project', name: 'current', path: '/current.json' }], errors: [] })
  await current
  reads[0].resolve({ entries: [{ kind: 'project', name: 'old', path: '/old.json' }], errors: [] })
  await old
  assert.equal(model.entries[0].path, '/current.json')
  const pending = model.refresh(); await flush()
  const closing = model.close()
  assert.equal(reads[2].signal.aborted, true)
  reads[2].resolve({ entries: [], errors: [] }); await pending; await closing
  assert.equal(model.entries[0].path, '/current.json')
})

test('a late library result preserves the selection moved while reading', async () => {
  const pending = deferred(), opened = []
  const model = new MusicWorkbench({ read: () => pending.promise,
    open: async entry => { opened.push(entry) } })
  const refreshing = model.refresh(); await flush()
  assert.equal(model.loading, true)
  model.move(1)
  const selected = model.entries[model.cursor]
  pending.resolve({ entries: [{ kind: 'project', name: 'new', path: '/new.json' }, ...model.entries], errors: [] })
  await refreshing
  assert.equal(model.entries[model.cursor], selected)
  await model.activate()
  assert.deepEqual(opened, [selected])
  await model.close()
})

test('a rejected project stays a source failure without starting a replacement editor', async () => {
  const requests = []
  const model = new MusicWorkbench({ open: async entry => { requests.push(entry); throw new Error('Project changed') } })
  await model.activate({ kind: 'project', name: 'selected', path: '/selected.json' })
  assert.deepEqual(requests, [{ kind: 'project', name: 'selected', path: '/selected.json' }])
  assert.equal(model.status, 'Project changed')
  assert.equal(model.child, null)
  await model.close()
})

test('inspection retires the previous worker and never applies its late result to a new selection', async t => {
  const jobs = [], entries = ['A', 'B', 'C'].map(name => ({ kind: 'project', name, path: `/${name}.json` }))
  const model = new MusicWorkbench({ read: async () => ({ entries, errors: [] }), inspect: entry => {
    const result = deferred(), exited = deferred()
    const job = { entry, result, exited, cancelled: false,
      promise: result.promise, completion: exited.promise, cancel() { this.cancelled = true } }
    jobs.push(job); return job
  } })
  t.after(async () => { const closing = model.close(); for (const job of jobs) { job.result.resolve({}); job.exited.resolve() }; await closing })
  await model.refresh(); await flush()
  assert.equal(jobs[0].entry.path, '/A.json')
  model.move(1); model.move(1); await flush()
  assert.equal(jobs[0].cancelled, true)
  assert.equal(jobs.length, 1)
  jobs[0].result.resolve({ kind: 'phrase', title: 'retired A' }); jobs[0].exited.resolve(); await flush()
  assert.equal(jobs.length, 2)
  assert.equal(jobs[1].entry.path, '/C.json')
  assert.equal(model.inspection.kind, 'loading')
  jobs[1].result.resolve({ kind: 'phrase', title: 'current C' }); jobs[1].exited.resolve(); await flush()
  assert.equal(model.inspection.info.title, 'current C')
  let returned = false
  const close = model.close().then(() => { returned = true }); await close
  assert.equal(returned, true)
})

test('opening a project waits for inspection cleanup and forwards its selected path unchanged', async t => {
  const result = deferred(), exited = deferred(), requests = []
  let cancelled = false
  const entry = { kind: 'project', name: 'Selected', path: '/selected.json' }
  const model = new MusicWorkbench({ read: async () => ({ entries: [entry], errors: [] }),
    inspect: () => ({ promise: result.promise, completion: exited.promise, cancel() { cancelled = true } }),
    open: async selected => { requests.push(selected) } })
  t.after(async () => { const closing = model.close(); result.resolve({}); exited.resolve(); await closing })
  await model.refresh(); await flush()
  const opening = model.activate(); await flush()
  assert.equal(cancelled, true); assert.deepEqual(requests, [])
  result.resolve({ kind: 'phrase', title: 'old observation' }); exited.resolve(); await opening
  assert.deepEqual(requests, [entry])
})
