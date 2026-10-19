import { readdir, readFile } from 'node:fs/promises'
import { join, resolve, basename } from 'node:path'
import { homedir } from 'node:os'
import { emitKeypressEvents } from 'node:readline'
import cliTruncate from 'cli-truncate'
import { safeText } from './terminal.mjs'

const actions = [
  { kind: 'phrase', name: 'New phrase' },
  { kind: 'arrangement', name: 'New arrangement' },
  { kind: 'recording', name: 'Record audio / MIDI' },
]
const identity = entry => JSON.stringify([entry.kind, entry.path ?? null])

export async function musicLibrary({ projectRoot, sessionRoot }, { signal } = {}) {
  const read = async (root, kind) => {
    signal?.throwIfAborted()
    let files
    try { files = await readdir(root, { withFileTypes: true }) }
    catch (error) { if (error.code === 'ENOENT') return []; throw error }
    signal?.throwIfAborted()
    return files.filter(file => kind === 'project'
      ? file.isFile() && file.name.endsWith('.json') : file.isDirectory())
      .sort((a, b) => a.name.localeCompare(b.name))
      .map(file => ({ kind, name: file.name, path: join(root, file.name) }))
  }
  const results = await Promise.allSettled([read(projectRoot, 'project'), read(sessionRoot, 'session')])
  signal?.throwIfAborted()
  return { entries: [...actions, ...results.flatMap(result => result.status === 'fulfilled' ? result.value : [])],
    errors: results.flatMap((result, index) => result.status === 'rejected'
      ? [{ root: index === 0 ? projectRoot : sessionRoot, message: result.reason.message }] : []) }
}

export async function openMusicEntry(entry, options) {
  switch (entry.kind) {
    case 'phrase': case 'project': case 'midi': {
      const { viewSequencer } = await import('./sequencer-tui.mjs')
      const initialDocument = entry.kind === 'midi'
        ? (await import('./midi-source.mjs')).importMidiSource(await readFile(entry.path, { signal: options.signal }), { name: basename(entry.path) })
        : undefined
      options.signal.throwIfAborted()
      return viewSequencer({ ...options, root: options.projectRoot,
        path: entry.kind === 'project' ? entry.path : undefined, initialDocument })
    }
    case 'arrangement': {
      const { viewArrangement } = await import('./arrangement-tui.mjs')
      options.signal.throwIfAborted()
      return viewArrangement({ ...options, root: options.projectRoot })
    }
    case 'recording': case 'session': {
      const { viewSession } = await import('./music-session.mjs')
      options.signal.throwIfAborted()
      return viewSession({ ...options, root: options.sessionRoot,
        directory: entry.kind === 'session' ? entry.path : undefined })
    }
    default: throw new Error('Unknown music library entry')
  }
}

// Own reads and one child view independently of the terminal renderer. The
// child keeps its own drafts and transport; home never substitutes a new one.
export class MusicWorkbench {
  constructor({ projectRoot = resolve('music-projects'), sessionRoot = resolve('music-sessions'),
    open = openMusicEntry, read = musicLibrary, changed = () => {}, ...options } = {}) {
    Object.assign(this, { projectRoot: resolve(projectRoot), sessionRoot: resolve(sessionRoot), open, read, changed, options })
    this.entries = [...actions]; this.errors = []; this.cursor = 0
    this.status = ''; this.closed = false; this.child = null; this.reads = new Set(); this.loading = false
  }
  async refresh() {
    if (this.closed || this.child) return
    this.reader?.abort()
    const reader = new AbortController(); this.reader = reader
    const selected = identity(this.entries[this.cursor])
    this.loading = true; this.changed()
    const pending = Promise.resolve().then(() => this.read(this, { signal: reader.signal }))
    this.reads.add(pending)
    try {
      const result = await pending
      if (this.closed || this.reader !== reader || reader.signal.aborted) return
      this.entries = result.entries; this.errors = result.errors
      this.cursor = Math.max(0, this.entries.findIndex(entry => identity(entry) === selected))
    } catch (error) {
      if (!this.closed && this.reader === reader && !reader.signal.aborted) this.status = error.message
    } finally {
      this.reads.delete(pending)
      if (this.reader === reader) { this.reader = null; this.loading = false; this.changed() }
    }
  }
  move(step) {
    if (this.closed || this.child) return
    this.cursor = Math.max(0, Math.min(this.entries.length - 1, this.cursor + step)); this.changed()
  }
  activate(entry = this.entries[this.cursor]) {
    if (this.closed || this.child || !entry) return this.child?.promise ?? Promise.resolve()
    this.reader?.abort()
    const controller = new AbortController(), child = { controller, promise: null }
    this.child = child
    child.promise = Promise.resolve().then(() => {
      controller.signal.throwIfAborted()
      return this.open(entry, { ...this.options, projectRoot: this.projectRoot, sessionRoot: this.sessionRoot,
        embedded: true, signal: controller.signal })
    }).catch(error => {
      if (!this.closed && !controller.signal.aborted) this.status = error.message
    }).finally(async () => {
      if (this.child === child) this.child = null
      if (!this.closed) await this.refresh()
    })
    return child.promise
  }
  async close() {
    this.closed = true; this.reader?.abort(); this.child?.controller.abort()
    await Promise.allSettled([...this.reads, this.child?.promise])
  }
}

export async function viewMusic(options = {}) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('Music workbench requires a terminal')
  const wasRaw = process.stdin.isRaw
  let finish, prompt = null
  const done = new Promise(resolve => { finish = resolve })
  const model = new MusicWorkbench({ ...options, changed: draw })
  function draw() {
    if (model.closed || model.child) return
    const rows = process.stdout.rows || 24, columns = process.stdout.columns || 80
    const available = Math.max(1, rows - 9), first = Math.max(0, model.cursor - available + 1)
    const lines = ['Music', 'Phrase · arrangement · audio / MIDI recording', '',
      ...model.entries.slice(first, first + available).map((entry, index) =>
        `${first + index === model.cursor ? '›' : ' '} ${entry.name}${entry.kind === 'project' ? '  · project' : entry.kind === 'session' ? '  · take' : ''}`),
      '', model.loading ? 'Reading library…' : model.status,
      ...model.errors.map(error => `${error.root}: ${error.message}`),
      `Projects: ${model.projectRoot}`, `Takes: ${model.sessionRoot}`]
    let output = '\x1b[H'
    for (let row = 0; row < rows; row++) output += `\x1b[${row + 1};1H\x1b[2K`
    // Labels are display-only; retained paths and identities are never sanitized.
    lines.slice(0, rows - 2).forEach((line, row) => {
      output += `\x1b[${row + 1};1H${cliTruncate(safeText(line), Math.max(0, columns - 1))}`
    })
    const footer = prompt === null ? '↑/↓ choose · Enter open · r refresh · :open PATH · :midi PATH · :session PATH' : ':' + prompt
    output += `\x1b[${rows - 1};1H${cliTruncate(safeText(footer), Math.max(0, columns - 1))}`
    output += `\x1b[${rows};1Hq / Esc: return`
    process.stdout.write(output)
  }
  function keypress(text, key = {}) {
    if (model.closed || model.child) return
    if (key.ctrl && key.name === 'c') { finish(); return }
    if (prompt !== null) {
      if (key.name === 'escape') prompt = null
      else if (key.name === 'backspace') prompt = [...prompt].slice(0, -1).join('')
      else if (key.name === 'return') {
        const line = prompt.trim(), split = line.indexOf(' ')
        const command = split < 0 ? line : line.slice(0, split), path = split < 0 ? '' : line.slice(split + 1).trim()
        prompt = null
        const kinds = { open: 'project', midi: 'midi', session: 'session' }
        if (Object.hasOwn(kinds, command) && path) {
          const expanded = path.startsWith('~/') ? join(homedir(), path.slice(2)) : resolve(path)
          model.activate({ kind: kinds[command], path: expanded, name: basename(expanded) })
        } else model.status = 'Use :open PROJECT.json, :midi SOURCE.mid or :session TAKE_DIRECTORY'
      } else if (text && !key.ctrl && !key.meta) prompt += text
    } else if (['q', 'escape'].includes(key.name)) finish()
    else if (text === ':') prompt = ''
    else if (['up', 'k'].includes(key.name)) model.move(-1)
    else if (['down', 'j'].includes(key.name)) model.move(1)
    else if (key.name === 'return') model.activate()
    else if (key.name === 'r') model.refresh()
    draw()
  }
  const onEnd = () => finish(), onSignal = () => finish(), onResize = () => draw()
  emitKeypressEvents(process.stdin); process.stdin.setRawMode(true); process.stdin.resume()
  process.stdin.on('keypress', keypress); process.stdin.on('end', onEnd); process.stdout.on('resize', onResize)
  options.signal?.addEventListener('abort', onSignal, { once: true })
  for (const name of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(name, onSignal)
  if (!options.embedded) process.stdout.write('\x1b[?1049h\x1b[?25l\x1b[2J')
  try { model.refresh(); if (options.signal?.aborted) finish(); await done }
  finally {
    await model.close()
    process.stdin.off('keypress', keypress); process.stdin.off('end', onEnd); process.stdout.off('resize', onResize)
    options.signal?.removeEventListener('abort', onSignal)
    for (const name of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.off(name, onSignal)
    if (!options.embedded) {
      process.stdout.write('\x1b[?25h\x1b[?1049l'); process.stdin.setRawMode(wasRaw ?? false); process.stdin.pause()
    }
  }
}
