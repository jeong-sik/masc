import { mkdir, readdir } from 'node:fs/promises'
import { basename, join, resolve, win32 } from 'node:path'
import { homedir } from 'node:os'
import { nativeJob, loadSelection, saveSelection, presetDirectory } from './vst.mjs'
import { safeText } from './terminal.mjs'

// A selection is a plug-in plus an optional saved sound. The state line and the
// picker both read these names so the two never disagree about what is chosen.
export function presetLabel(presetPath) {
  return presetPath ? basename(presetPath).replace(/\.vstpreset$/i, '') : 'default state'
}

export function selectionLabel(selection) {
  return selection ? `${selection.name} · ${presetLabel(selection.preset_path)}` : 'SoundFont'
}

// Project sounds are already validated when loaded or adopted. Read their
// captured identity here, without reopening paths or hashing inline font bytes.
export function projectSoundLabel(sound) {
  if (sound === undefined || sound.kind === 'unselected') return 'Choose an instrument'
  switch (sound.kind) {
    case 'vst':
      return safeText(`VST · ${selectionLabel(sound.selection)} · ${sound.instrument.version}`)
    case 'soundfont':
      if (sound.engine === undefined) return 'SoundFont · AlphaSynth'
      if (sound.engine.kind === 'fluidsynth') {
        return safeText(`SoundFont · ${sound.font.name} · FluidSynth ${sound.engine.version} · ${sound.bankStyle.toUpperCase()} · control ${sound.engine.controlFrames} samples`)
      }
      throw new TypeError(`Unsupported SoundFont engine: ${sound.engine.kind}`)
    default:
      throw new TypeError(`Unsupported project sound: ${sound.kind}`)
  }
}

// The picker's own actions as data: the footer renders them and the tests read
// the same source, so an action is advertised only where the keys reach it.
export function pickerActions(view) {
  if (!view) return []
  if (view.kind === 'loading') return [{ key: 'Esc', label: 'cancel' }]
  if (view.kind === 'preset_name') {
    return [{ key: 'Enter', label: 'open sound browser' }, { key: 'Esc', label: 'cancel' }]
  }
  if (view.kind === 'preset_path') {
    return [{ key: 'Enter', label: 'load preset file' }, { key: 'Esc', label: 'cancel' }]
  }
  const actions = [{ key: '↑↓/j k', label: 'choose' }, { key: '/', label: 'search' },
    { key: 'Enter', label: view.kind === 'presets' ? 'play' : 'select' }]
  if (view.kind === 'presets') {
    actions.push({ key: 'e', label: 'new sound' }, { key: 'p', label: 'preset file' })
  }
  actions.push({ key: 'Esc', label: 'cancel' }, { key: 's', label: 'stop' })
  return actions
}

export function pickerFooter(view) {
  return pickerActions(view).map(({ key, label }) => `${key}:${label}`).join('  ')
}

// Owns native loading and selection, independently of score rendering and
// playback. Leaving the menu retires every pending load/editor/read result.
export class InstrumentPicker {
  constructor({ directory, notify, selected, soundfont, failed, active = () => null, run = nativeJob }) {
    Object.assign(this, { directory, notify, selected, soundfont, failed, active, run })
    this.view = null
    this.epoch = 0
    this.job = null
    this.jobs = new Map()
    this.recent = null
  }

  // Whether a menu row is the live selection, so the picker can mark it. The
  // SoundFont row is active only while no native instrument is loaded.
  isActive(item) {
    const active = typeof this.active === 'function' ? this.active() : null
    if (item?.kind === 'soundfont') return active === null
    if (!active || !item) return false
    if (item.plugin_path !== undefined && item.plugin_path !== active.plugin_path) return false
    if (item.plugin_name !== undefined && item.plugin_name !== active.plugin_name) return false
    if (item.preset_path !== undefined) return item.preset_path === active.preset_path
    return true
  }

  close() {
    ++this.epoch
    for (const job of this.jobs.values()) job.cancel()
    this.job = null
    this.view = null
    this.notify()
  }

  async settled() { await Promise.allSettled([...this.jobs.keys()]) }

  async work(request, epoch) {
    const job = this.run(request)
    this.job = job
    this.jobs.set(job.promise, job)
    try {
      const result = await job.promise
      return epoch === this.epoch ? result : null
    } finally {
      this.jobs.delete(job.promise)
      if (this.job === job) this.job = null
    }
  }

  async attempt(action) {
    const epoch = this.epoch
    const previous = this.view
    try { await action(epoch) }
    catch (error) {
      if (epoch !== this.epoch) return
      this.view = previous?.kind === 'loading'
        ? { kind: 'plugins', title: 'VST unavailable · install scripts/install-vst-host.sh',
          items: this.soundfont ? [{ kind: 'soundfont', name: 'SoundFont' }] : [], cursor: 0, query: '', searching: false }
        : previous
      this.failed(error)
      this.notify()
    }
  }

  async open() {
    this.close()
    const epoch = this.epoch
    this.view = { kind: 'loading', title: 'Finding installed VST3 plug-ins…' }
    this.notify()
    await this.attempt(async () => {
      let selectionFailure
      let recent = null
      try { recent = await loadSelection(this.directory) }
      catch (error) { selectionFailure = error }
      if (epoch !== this.epoch) return
      this.recent = recent
      const result = await this.work({ operation: 'candidates' }, epoch)
      if (result === null) return
      if (!Array.isArray(result.candidates) || result.candidates.some(item =>
        typeof item?.path !== 'string' || typeof item?.name !== 'string')) {
        throw new Error('VST host returned an invalid plug-in catalog')
      }
      const items = [...(this.soundfont ? [{ kind: 'soundfont', name: 'SoundFont' }] : []),
        ...result.candidates.map(item => ({ name: item.name, plugin_path: item.path }))]
      this.view = { kind: 'plugins', title: 'Choose a VST instrument · candidates are checked when selected',
        items, cursor: Math.max(0, items.findIndex(item => item.plugin_path === this.recent?.plugin_path)),
        query: '', searching: false }
      if (this.recent && !items.some(item => item.plugin_path === this.recent.plugin_path)) {
        this.failed(new Error(`Previously selected instrument is unavailable: ${this.recent.name}`))
      }
      if (selectionFailure) this.failed(selectionFailure)
      this.notify()
    })
  }

  items() {
    if (!this.view?.items) return []
    const query = this.view.query.toLocaleLowerCase()
    return this.view.items.filter(item => item.name.toLocaleLowerCase().includes(query))
  }

  async presets(instrument, epoch, preferred = this.recent?.preset_path) {
    const folder = presetDirectory(this.directory, instrument.plugin_path, instrument.plugin_name)
    let files
    try { files = await readdir(folder, { withFileTypes: true }) }
    catch (error) { if (error.code !== 'ENOENT') throw error; files = [] }
    if (epoch !== this.epoch) return
    const identity = { plugin_path: instrument.plugin_path, plugin_name: instrument.plugin_name ?? null }
    const items = [{ ...identity, name: 'Default instrument state', preset_path: null },
      ...files.filter(file => file.isFile() && file.name.endsWith('.vstpreset'))
        .map(file => ({ ...identity, name: file.name, preset_path: join(folder, file.name) }))]
    if (preferred && !items.some(item => item.preset_path === preferred)) {
      items.push({ ...identity, name: basename(preferred), preset_path: preferred })
    }
    this.view = { kind: 'presets', title: `${instrument.name} · choose a sound`,
      instrument, items, cursor: Math.max(0, items.findIndex(item => item.preset_path === preferred)),
      query: '', searching: false }
    this.notify()
  }

  async choose() {
    const view = this.view
    const item = this.items()[view?.cursor ?? 0]
    if (!item) return
    await this.attempt(async epoch => {
      if (item.kind === 'soundfont') {
        this.close()
        this.soundfont()
        return
      }
      if (view.kind === 'presets') {
        this.view = { kind: 'loading', title: 'Saving the selected sound…' }
        this.notify()
        const selection = { ...view.instrument, preset_path: item.preset_path }
        await saveSelection(this.directory, selection)
        if (epoch !== this.epoch) return
        this.recent = selection
        this.close()
        this.selected(selection)
        return
      }
      const identity = { plugin_path: item.plugin_path, plugin_name: item.plugin_name ?? null }
      this.view = { kind: 'loading', title: `Loading ${item.name}…` }
      this.notify()
      const result = await this.work({ operation: 'inspect', ...identity }, epoch)
      if (result === null) return
      if (!result.instrument) {
        if (!Array.isArray(result.plugin_names) || result.plugin_names.some(name => typeof name !== 'string')) {
          throw new Error('VST host returned invalid instrument names')
        }
        this.view = { kind: 'plugins', title: 'Choose an instrument inside this bundle',
          items: result.plugin_names.map(name => ({ ...identity, plugin_name: name, name })),
          cursor: Math.max(0, result.plugin_names.findIndex(name =>
            this.recent?.plugin_path === identity.plugin_path && name === this.recent.plugin_name)),
          query: '', searching: false }
        this.notify()
        return
      }
      if (result.instrument.is_instrument !== true || typeof result.instrument.name !== 'string') {
        throw new Error('The selected plug-in is not a verified MIDI instrument')
      }
      const instrument = { ...identity, name: result.instrument.name }
      const preferred = this.recent?.plugin_path === identity.plugin_path
        && this.recent?.plugin_name === identity.plugin_name ? this.recent.preset_path : null
      await this.presets(instrument, epoch, preferred)
    })
  }

  async edit() {
    const view = this.view
    if (view?.kind !== 'presets') return
    const preset = this.items()[view.cursor]?.preset_path ?? null
    this.view = { kind: 'preset_name', title: 'Name the sound to save',
      instrument: view.instrument, preset_path: preset, query: '', searching: false }
    this.notify()
  }

  async saveNamedPreset() {
    const view = this.view
    if (view?.kind !== 'preset_name') return
    await this.attempt(async epoch => {
      // The name denotes one file in this instrument's own preset directory.
      // Do not turn a sound name into a path or silently sanitize its spelling.
      const extension = '.vstpreset'
      const name = view.query.toLowerCase().endsWith(extension)
        ? view.query.slice(0, -extension.length) : view.query
      if (!name.trim() || name === '.' || name === '..' || view.query.includes('\0')
          || basename(view.query) !== view.query || win32.basename(view.query) !== view.query) {
        throw new Error('Choose a sound name without directories')
      }
      const folder = presetDirectory(this.directory, view.instrument.plugin_path, view.instrument.plugin_name)
      const path = join(folder, `${name}.vstpreset`)
      this.view = { kind: 'loading', title: 'Choose a sound in the native editor; close its window to save' }
      this.notify()
      await mkdir(folder, { recursive: true, mode: 0o700 })
      if (epoch !== this.epoch) return
      const result = await this.work({ operation: 'edit', ...view.instrument,
        preset_path: view.preset_path, output_path: path }, epoch)
      if (result === null) return
      await this.presets(view.instrument, epoch, result.preset_path)
    })
  }

  async keypress(text, key) {
    const view = this.view
    if (!view) return
    if (key.name === 'escape') { this.close(); return }
    if (view.kind === 'loading') return
    if (view.searching) {
      if (key.name === 'return') view.searching = false
      else if (key.name === 'backspace') { view.query = view.query.slice(0, -1); view.cursor = 0 }
      else if (text && !key.ctrl && !key.meta) { view.query += text; view.cursor = 0 }
    } else if (view.kind === 'preset_name') {
      if (key.name === 'return') { await this.saveNamedPreset(); return }
      if (key.name === 'backspace') view.query = [...view.query].slice(0, -1).join('')
      else if (text && !key.ctrl && !key.meta) view.query += text
    } else if (view.kind === 'preset_path') {
      if (key.name === 'return') {
        const path = view.query.startsWith('~/') ? join(homedir(), view.query.slice(2)) : resolve(view.query)
        await this.presets(view.instrument, this.epoch, path)
        return
      }
      if (key.name === 'backspace') view.query = view.query.slice(0, -1)
      else if (text && !key.ctrl && !key.meta) view.query += text
    } else {
      switch (key.name) {
        case 'up': case 'k': view.cursor = Math.max(0, view.cursor - 1); break
        case 'down': case 'j': view.cursor = Math.min(Math.max(0, this.items().length - 1), view.cursor + 1); break
        case 'return': await this.choose(); return
        case 'e': await this.edit(); return
        case 'p':
          if (view.kind === 'presets') this.view = { kind: 'preset_path', title: 'Path to a .vstpreset file',
            instrument: view.instrument, query: '', searching: false }
          break
        default: if (text === '/') view.searching = true
      }
    }
    this.notify()
  }
}
