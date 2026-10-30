import test from 'node:test'
import assert from 'node:assert/strict'
import { writeFileSync, renameSync } from 'node:fs'
import filesystem from 'node:fs/promises'
import { mkdtemp, readdir, readFile, open, rm, stat } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { tmpdir } from 'node:os'
import { syncBuiltinESMExports } from 'node:module'
import { newProject } from '../sequencer-project.mjs'
import { saveProject, loadProject } from '../sequencer-files.mjs'

async function history(directory) {
  const result = []
  for (const name of await readdir(directory)) {
    if (!name.startsWith('.song.json.save-')) continue
    for (const file of await readdir(join(directory, name))) {
      const path = join(directory, name, file)
      result.push({ path, file, text: await readFile(path, 'utf8') })
    }
  }
  return result
}
async function fixture(run) {
  const directory = await mkdtemp(join(tmpdir(), 'masc-sequencer-save-'))
  try { await run(directory, join(directory, 'song.json')) }
  finally { await rm(directory, { recursive: true, force: true }) }
}

test('normal save/reopen retains the claimed inode for late writes through an external held FD', async () => {
  await fixture(async (directory, path) => {
    const original = newProject(), revision = await saveProject(path, original)
    const held = await open(path, 'r+')
    try {
      const local = { ...original, title: 'local phrase' }
      const next = await saveProject(path, local, revision)
      assert.equal(typeof next, 'string')
      const reopened = await loadProject(path)
      assert.equal(reopened.revision, next)
      assert.deepEqual(reopened.project, local)
      // This happens after the revision comparison AND publication have finished.
      const external = 'external editor wrote its previously opened inode\n'
      await held.truncate(0); await held.writeFile(external); await held.sync()
      assert.deepEqual((await loadProject(path)).project, local)
      const retained = await history(directory)
      assert.ok(retained.some(file => file.file === 'previous.json' && file.text === external))
      assert.ok(retained.some(file => file.file === 'local.json' && file.text === JSON.stringify(local, null, 2) + '\n'))
      assert.equal((await stat(path)).mode & 0o777, 0o600)
    } finally { await held.close() }
  })
})

test('an external edit at the real candidate-open boundary retains both versions on rejection', async () => {
  await fixture(async (directory, path) => {
    const original = newProject(), revision = await saveProject(path, original)
    const local = { ...original, title: 'local candidate' }, external = 'external edit during save\n'
    let injected = false, failure
    const open = filesystem.open
    filesystem.open = async (file, ...options) => {
      const handle = await open(file, ...options)
      if (!injected && file.endsWith('/local.json')) {
        injected = true; writeFileSync(path, external)
      }
      return handle
    }
    syncBuiltinESMExports()
    try { await saveProject(path, local, revision).catch(error => { failure = error }) }
    finally { filesystem.open = open; syncBuiltinESMExports() }
    assert.equal(injected, true)
    assert.match(failure?.message ?? '', /changed on disk/)
    assert.equal(await readFile(path, 'utf8'), external)
    const retained = await history(directory)
    for (const text of [external, JSON.stringify(local, null, 2) + '\n']) {
      const file = retained.find(file => file.text === text && failure.message.includes(file.path))
      assert.ok(file, `Missing retained version: ${text}`)
    }
  })
})

test('external pathname replacement at the real claim boundary preserves all three versions', async () => {
  await fixture(async (directory, path) => {
    const original = newProject(), revision = await saveProject(path, original)
    const local = { ...original, title: 'local candidate' }, external = 'external atomic replacement\n'
    let injected = false, failure
    const rename = filesystem.rename
    filesystem.rename = async (from, to) => {
      const result = await rename(from, to)
      // The actual rename has completed. Control only when the unrelated
      // editor publishes its file, rather than depending on watch delivery.
      if (!injected && from === path) {
        injected = true
        const replacement = join(directory, 'external-replacement')
        writeFileSync(replacement, external); renameSync(replacement, path)
      }
      return result
    }
    syncBuiltinESMExports()
    try { await saveProject(path, local, revision).catch(error => { failure = error }) }
    finally { filesystem.rename = rename; syncBuiltinESMExports() }
    assert.equal(injected, true)
    assert.equal(failure?.code, 'EEXIST')
    assert.equal(await readFile(path, 'utf8'), external)
    const retained = await history(directory)
    assert.ok(retained.some(file => file.file === 'previous.json' && file.text === JSON.stringify(original, null, 2) + '\n'))
    assert.ok(retained.some(file => file.file === 'local.json' && file.text === JSON.stringify(local, null, 2) + '\n'))
  })
})

test('new-document publication is exclusive and leaves a complete private local candidate on conflict', async () => {
  await fixture(async (directory, path) => {
    const local = newProject(), external = 'another editor created the destination\n'
    let injected = false, failure
    const link = filesystem.link
    filesystem.link = async (from, to) => {
      if (!injected && to === path) {
        injected = true; writeFileSync(path, external)
      }
      return link(from, to)
    }
    syncBuiltinESMExports()
    try { await saveProject(path, local).catch(error => { failure = error }) }
    finally { filesystem.link = link; syncBuiltinESMExports() }
    assert.equal(injected, true)
    assert.equal(failure?.code, 'EEXIST')
    assert.equal(await readFile(path, 'utf8'), external)
    const retained = await history(directory), candidate = retained.find(file => file.file === 'local.json')
    assert.deepEqual(JSON.parse(candidate.text), local)
    assert.ok(failure.message.includes(candidate.path))
    assert.equal((await stat(candidate.path)).mode & 0o777, 0o600)
    assert.equal((await stat(dirname(candidate.path))).mode & 0o777, 0o700)
  })
})

test('a live-path in-place write immediately after the real publication cannot mutate the retained local candidate', async () => {
  await fixture(async (directory, path) => {
    const original = newProject(), revision = await saveProject(path, original)
    const local = { ...original, title: 'local published phrase' }, external = 'external write to the published pathname\n'
    let injected = false
    const link = filesystem.link
    filesystem.link = async (from, to) => {
      const result = await link(from, to)
      if (!injected && to === path) { injected = true; writeFileSync(path, external) }
      return result
    }
    syncBuiltinESMExports()
    try { await saveProject(path, local, revision) }
    finally { filesystem.link = link; syncBuiltinESMExports() }
    assert.equal(injected, true)
    const versions = await history(directory)
    const candidate = versions.find(file => file.file === 'local.json' && JSON.parse(file.text).title === local.title)
    assert.ok(candidate)
    const [liveStat, candidateStat] = await Promise.all([stat(path), stat(candidate.path)])
    assert.notEqual(liveStat.ino, candidateStat.ino)
    assert.equal(await readFile(path, 'utf8'), external)
    assert.deepEqual(JSON.parse(await readFile(candidate.path, 'utf8')), local)
  })
})
