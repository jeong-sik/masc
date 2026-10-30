import { listMidiSources } from './midi-input.mjs'

// A dismissed/refreshed discovery owns its process until settlement but can
// never replace the current catalog or choose a device on the user's behalf.
export class MidiSourcePicker {
  constructor({ selected, notify = () => {}, discover = listMidiSources }) {
    Object.assign(this, { selected, notify, discover })
    this.view = null; this.epoch = 0; this.jobs = new Set(); this.preferred = undefined
  }
  retire() {
    ++this.epoch
    for (const job of this.jobs) job.controller.abort(new Error('MIDI source selection cancelled'))
  }
  close() {
    this.retire(); this.view = null; this.preferred = undefined; this.notify()
  }
  async settled() { await Promise.allSettled([...this.jobs].map(job => job.promise)) }
  open() {
    const preferred = this.preferred
    this.retire()
    const epoch = this.epoch, controller = new AbortController()
    this.view = { kind: 'loading' }; this.notify()
    const job = { controller }
    job.promise = Promise.resolve().then(() => this.discover({ signal: controller.signal })).then(sources => {
      if (epoch !== this.epoch) return
      if (preferred === undefined) this.preferred = sources[0]?.id
      this.view = { kind: 'ready', sources, cursor: preferred === undefined ? 0 : sources.findIndex(source => source.id === preferred) }
    }, error => {
      if (epoch === this.epoch) this.view = { kind: 'failed', error: error instanceof Error ? error.message : String(error) }
    }).finally(() => { this.jobs.delete(job); this.notify() })
    this.jobs.add(job)
    return job.promise
  }
  keypress(text, key = {}) {
    if (['escape', 'q'].includes(key.name)) { this.close(); return }
    if (key.name === 'r') { this.open(); return }
    if (this.view?.kind !== 'ready') return
    const { sources, cursor } = this.view
    if (['up', 'k', 'down', 'j'].includes(key.name)) {
      const direction = ['up', 'k'].includes(key.name) ? -1 : 1
      let next = -1
      if (sources.length) next = cursor < 0 ? direction > 0 ? 0 : sources.length - 1 : (cursor + direction + sources.length) % sources.length
      this.view = { ...this.view, cursor: next }
      if (this.view.cursor >= 0) this.preferred = sources[this.view.cursor].id
      this.notify()
    } else if (key.name === 'return') {
      const source = sources[cursor]
      if (!source) return
      this.close(); this.selected(source.id)
    }
  }
}
