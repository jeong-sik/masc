import { newArrangement, validateArrangement, editArrangement, arrangementSchedule, arrangementTakes, arrangementID } from './arrangement.mjs'
import { isDeepStrictEqual } from 'node:util'
import { umpVariantAsset } from './ump-source.mjs'
import { midiSourcePattern } from './midi-source.mjs'
import { captureRange, captureRegionFromSeconds } from './capture-time.mjs'
import { practiceRange } from './practice-source.mjs'
import { beats, PPQ } from './sequencer-project.mjs'
import { calibrationSelection } from './audio-calibration.mjs'
import { manualCapturePlacement } from './capture-placement.mjs'
import { validateCalibrationCapture, calibrationResidual } from './calibration-profile.mjs'
import { validateSound } from './project-sound.mjs'

export { arrangementTakes }

function reconcile(editor, project) {
  const selected = project.clips.find(clip => clip.id === editor.region)
  const asset = project.assets.some(asset => asset.id === editor.asset) ? editor.asset : project.assets[0]?.id ?? null
  return { ...editor, project, schedule: arrangementSchedule(project, { all: true }),
    lane: selected?.lane ?? (project.lanes.some(lane => lane.id === editor.lane) ? editor.lane : project.lanes[0]?.id ?? null),
    region: selected?.id ?? null,
    asset, pattern: asset === editor.asset ? editor.pattern : undefined }
}
export function arrangementEditor(project = newArrangement()) {
  validateArrangement(project)
  return reconcile({ tick: 0, step: PPQ, lane: null, region: null, asset: null, undo: [], redo: [] }, project)
}
export const selectedRegion = editor => editor.project.clips.find(clip => clip.id === editor.region)
// A verified opening snapshot can preserve an edited draft after its IO owner
// fails. Current file verification is still required before save or playback.
export function arrangementUmpDraft(editor, source, ump) {
  const original = editor.project.assets.find(asset => asset.id === source.asset.id)
  if (original?.kind !== 'capture' || !isDeepStrictEqual(original, source.asset)) throw new Error('UMP draft source no longer matches the arrangement')
  const asset = { ...umpVariantAsset(original, source.packets, ump), id: arrangementID(editor.project.assets, 'asset') }
  return arrangementImported(editor, { project: editArrangement(editor.project, { kind: 'asset-add', asset }), asset: asset.id })
}
function commit(editor, project) {
  return reconcile({ ...editor, undo: [...editor.undo, editor.project], redo: [] }, project)
}
// File IO supplies a complete immutable import result. Adoption happens once,
// after its owning controller has accepted completion, and is undoable.
export function arrangementImported(editor, { project, asset, pattern }) {
  validateArrangement(project)
  const source = project.assets.find(item => item.id === asset)
  if (!source) throw new Error('Imported asset is missing')
  if (pattern !== undefined) {
    if (source.kind !== 'midi') throw new Error('Only MIDI assets have patterns')
    midiSourcePattern(source.source, { pattern })
  }
  return { ...commit(editor, project), asset, pattern }
}
export function arrangementPracticePass(editor, target, selected) {
  if (target.asset !== selected.asset || target.pass !== selected.pass || !selected.cut) throw new Error('Practice pass response changed its selection')
  if (target.region === null) return place(editor, target.asset, target.tick, selected.cut)
  const region = editor.project.clips.find(clip => clip.id === target.region && clip.asset === target.asset)
  if (!region) throw new Error('Selected practice region is no longer available')
  const next = edit(editor, { kind: 'region-change', id: region.id, ...selected.cut })
  return { ...next, asset: target.asset, pattern: undefined, lane: region.lane, region: region.id, tick: region.position }
}
export function arrangementSound(editor, id, sound) {
  validateSound(sound)
  if (sound.kind !== 'vst') throw new Error('Choose a VST instrument for arrangement playback')
  const asset = editor.project.assets.find(asset => asset.id === id)
  if (!asset || asset.kind !== 'midi') throw new Error('Select a MIDI region or asset to choose its instrument')
  const next = { ...asset, source: { ...asset.source, sound: structuredClone(sound) },
    ...(asset.phrase ? { phrase: { ...asset.phrase, sound: structuredClone(sound) } } : {}) }
  const project = { ...editor.project, assets: editor.project.assets.map(asset => asset.id === id ? next : asset) }
  validateArrangement(project)
  return commit(editor, project)
}
function edit(editor, value) { return commit(editor, editArrangement(editor.project, value)) }
export function arrangementPracticeSound(editor, asset, sound) { return edit(editor, { kind: 'practice-sound', asset, sound }) }
export function arrangementRecordingCorrection(editor, correction) { return edit(editor, { kind: 'recording-correction', correction }) }
export function arrangementCalibrated(editor, { profile, match, output }) {
  const clip = selectedRegion(editor), asset = editor.project.assets.find(asset => asset.id === clip?.asset)
  validateCalibrationCapture(profile, asset, clip ?? {}, output ?? null)
  if (!Number.isSafeInteger(match) || !profile.pulses[match]) throw new Error('Choose one inspected calibration pulse')
  return edit(editor, { kind: 'region-change', id: clip.id, placement: { kind: 'calibrated', match,
    advanceNanoseconds: calibrationResidual(profile, profile.pulses[match]), profile } })
}
function laneID(editor) {
  if (!editor.lane) throw new Error('Select an arrangement lane')
  return editor.lane
}
function regionID(editor) {
  if (!selectedRegion(editor)) throw new Error('Select a region with Up/Down or :select')
  return editor.region
}
function position(value) {
  if (!Number.isSafeInteger(value) || value < 0) throw new Error('Invalid arrangement cursor position')
  return value
}
function place(editor, assetID, tick, { offset, extent, repeat = 1, pattern, sourceDivisor } = {}) {
  const asset = editor.project.assets.find(asset => asset.id === assetID)
  if (!asset) throw new Error('Select an imported asset')
  offset ??= ['capture', 'practice'].includes(asset.kind) ? '0' : 0
  extent ??= asset.kind === 'practice' ? practiceRange(asset).extent : asset.kind === 'capture' ? captureRange(asset).extent : asset.kind === 'wave' ? asset.metadata.frames : midiSourcePattern(asset.source, { pattern }).ticks
  let project = editor.project, lane = project.lanes.find(lane => lane.id === editor.lane && lane.kind === asset.kind)
  if (!lane) {
    project = editArrangement(project, { kind: 'lane-add', sourceKind: asset.kind, name: asset.name })
    lane = project.lanes.at(-1)
  }
  project = editArrangement(project, { kind: 'region-add', asset: asset.id, lane: lane.id, name: asset.name,
    position: tick, offset, extent, repeat, ...(pattern === undefined ? {} : { pattern }),
    ...(sourceDivisor === undefined ? {} : { sourceDivisor }) })
  const next = commit(editor, project)
  return { ...next, asset: asset.id, pattern, lane: lane.id, region: project.clips.at(-1).id, tick }
}
export function arrangementAction(editor, action) {
  switch (action.kind) {
    case 'asset': {
      const assets = editor.project.assets
      if (!assets.length) return editor
      const asset = assets[(assets.findIndex(asset => asset.id === editor.asset) + 1) % assets.length].id
      return { ...editor, asset, pattern: asset === editor.asset ? editor.pattern : undefined }
    }
    case 'cursor': return { ...editor, tick: position(Math.max(0, editor.tick + action.ticks)) }
    case 'lane': {
      const lanes = editor.project.lanes
      if (!lanes.length) return editor
      const index = lanes.findIndex(lane => lane.id === editor.lane)
      return { ...editor, lane: lanes[(index + 1) % lanes.length].id, region: null }
    }
    case 'region': {
      const regions = editor.schedule.filter(clip => clip.lane === editor.lane)
      if (!regions.length) return { ...editor, region: null }
      let index = regions.findIndex(clip => clip.id === editor.region)
      index = index < 0 ? action.direction > 0 ? 0 : regions.length - 1
        : (index + action.direction + regions.length) % regions.length
      const clip = regions[index]
      return { ...editor, region: clip.id, asset: clip.asset, pattern: clip.pattern, tick: clip.position }
    }
    case 'place': return place(editor, editor.asset, editor.tick, { pattern: editor.pattern })
    case 'remove': return edit(editor, { kind: 'region-remove', id: regionID(editor) })
    case 'move': return edit(editor, { kind: 'region-change', id: regionID(editor), position: position(selectedRegion(editor).position + action.ticks) })
    case 'duplicate': {
      const next = edit(editor, { kind: 'region-duplicate', id: regionID(editor), position: action.tick ?? editor.tick })
      return { ...next, region: next.project.clips.at(-1).id }
    }
    case 'mute': case 'solo': return edit(editor, { kind: `lane-${action.kind}`, id: laneID(editor) })
    case 'undo': case 'redo': {
      if (!editor[action.kind].length) return editor
      const other = action.kind === 'undo' ? 'redo' : 'undo'
      return reconcile({ ...editor, [action.kind]: editor[action.kind].slice(0, -1), [other]: [...editor[other], editor.project] }, editor[action.kind].at(-1))
    }
    default: throw new Error('Unknown arrangement action')
  }
}
export function arrangementTakeSelected(editor, { asset, cycle }) {
  const group = arrangementTakes(editor.project, asset)
  if (!group.takes.some(take => take.cycle === cycle)) throw new Error('Take has no remaining regions')
  const project = group.selectedCycle === cycle ? editor.project : editArrangement(editor.project, { kind: 'take-select', asset, cycle })
  const clip = project.clips.find(clip => clip.asset === asset && clip.takeCycle === cycle)
  return { ...(project === editor.project ? editor : commit(editor, project)), asset, pattern: clip.pattern, lane: clip.lane, region: clip.id, tick: clip.position }
}
function commandInput(line) {
  line = line.trim()
  const boundary = line.search(/\s/), command = boundary < 0 ? line : line.slice(0, boundary)
  const tail = boundary < 0 ? '' : line.slice(boundary).trim(), args = tail ? tail.split(/\s+/) : []
  return { command, tail, args }
}
// Lexical admission has no document effects or selected-asset requirements.
// Stop can retire earlier queued work before semantic command execution begins.
export function arrangementCommandAdmission(line) {
  const { command, args } = commandInput(line)
  return { kind: command === 'stop' && !args.length ? 'stop' : 'queued' }
}
export function arrangementCommand(editor, line) {
  const { command, tail, args } = commandInput(line)
  const count = (min, max = min) => { if (args.length < min || args.length > max) throw new Error(`Wrong arguments for ${command}; use :help`) }
  const ordinalLane = value => {
    const index = Number(value) - 1
    if (!Number.isSafeInteger(index) || !editor.project.lanes[index]) throw new Error('Unknown arrangement lane')
    return editor.project.lanes[index].id
  }
  const pattern = value => {
    if (value === undefined) return undefined
    const number = Number(value)
    if (!Number.isSafeInteger(number) || number < 1) throw new Error('Pattern number starts at 1')
    return number - 1
  }
  const sourceRange = (assetID, offset, extent) => {
    const asset = editor.project.assets.find(asset => asset.id === assetID)
    if (!asset) throw new Error('Select an imported asset')
    return asset.kind === 'practice' ? { offset, extent, sourceDivisor: undefined }
      : asset.kind === 'capture' ? { offset, extent } : { offset: Number(offset), extent: Number(extent) }
  }
  const timeRange = (assetID, start, duration) => {
    const asset = editor.project.assets.find(asset => asset.id === assetID && asset.kind === 'capture')
    if (!asset) throw new Error('Choose a captured source for a time-based trim')
    return captureRegionFromSeconds(asset, start, duration)
  }
  let value
  switch (command) {
    case 'practice-soundfont':
      count(1, Number.MAX_SAFE_INTEGER)
      if (!editor.project.assets.some(asset => asset.id === args[0] && asset.kind === 'practice')) throw new Error('Choose a raw practice asset for SoundFont audition')
      return { editor, effect: { kind: command, asset: args[0], ...(args.length > 1 ? { path: args.slice(1).join(' ') } : {}) } }
    case 'practice-sound-original':
      count(1); value = { kind: 'practice-sound', asset: args[0] }; break
    case 'takes': {
      count(0, 1); const asset = args[0] ?? editor.asset
      arrangementTakes(editor.project, asset)
      return { editor: { ...editor, asset, pattern: undefined }, effect: { kind: 'takes', asset } }
    }
    case 'take': {
      count(1, 2); const asset = args[1] ?? editor.asset, group = arrangementTakes(editor.project, asset)
      let cycle
      if (args[0] === 'next' || args[0] === 'previous') {
        const takes = group.takes, selected = BigInt(group.selectedCycle)
        if (!takes.length) throw new Error('Take has no remaining regions')
        cycle = args[0] === 'next' ? (takes.find(take => BigInt(take.cycle) > selected) ?? takes[0]).cycle
          : (takes.findLast(take => BigInt(take.cycle) < selected) ?? takes.at(-1)).cycle
      } else {
        if (!/^[1-9][0-9]*$/.test(args[0])) throw new Error('Choose a positive original take number, next or previous')
        cycle = String(BigInt(args[0]) - 1n)
      }
      const selection = { kind: 'take-selection', asset, cycle }
      return { editor: arrangementTakeSelected(editor, selection), selection }
    }
    case 'practice':
      count(2)
      if (!['on', 'off'].includes(args[1])) throw new Error('Choose metronome on or off')
      value = { kind: 'practice', practice: { countInBars: Number(args[0]), metronome: args[1] === 'on' } }; break
    case 'phrase': count(0); return { editor, effect: { kind: command } }
    case 'capture-midi': {
      count(0, 1); const asset = args[0] ?? editor.asset
      if (!editor.project.assets.some(item => item.id === asset && item.kind === 'capture')) throw new Error('Choose a captured WAV/MIDI take')
      return { editor, effect: { kind: command, asset } }
    }
    case 'capture-midi-region': {
      count(0); const clip = selectedRegion(editor)
      if (!clip || clip.component === 'audio' || !editor.project.assets.some(asset => asset.id === clip.asset && asset.kind === 'capture')) throw new Error('Select an original captured MIDI region first')
      return { editor, effect: { kind: command, asset: clip.asset, tick: editor.tick, cut: { offset: clip.offset, extent: clip.extent } } }
    }
    case 'edit-ump': {
      count(0, 1); const asset = args[0] ?? editor.asset
      if (!editor.project.assets.some(item => item.id === asset && item.kind === 'capture')) throw new Error('Choose a captured UMP source')
      return { editor, effect: { kind: command, asset } }
    }
    case 'practice-midi': case 'practice-backing': {
      count(0, 1); const asset = args[0] ?? editor.asset
      if (!editor.project.assets.some(item => item.id === asset && item.kind === 'practice')) throw new Error('Choose a raw practice take')
      return { editor, effect: { kind: command, asset } }
    }
    case 'practice-midi-region': {
      count(0); const clip = selectedRegion(editor)
      if (!clip || !editor.project.assets.some(asset => asset.id === clip.asset && asset.kind === 'practice')) throw new Error('Select an original practice region first')
      return { editor, effect: { kind: command, asset: clip.asset, tick: editor.tick,
        cut: { offset: clip.offset, extent: clip.extent, ...(clip.sourceDivisor === undefined ? {} : { sourceDivisor: clip.sourceDivisor }) } } }
    }
    case 'practice-passes': case 'practice-pass': {
      count(command === 'practice-pass' ? 1 : 0, command === 'practice-pass' ? 2 : 1)
      const asset = args[command === 'practice-pass' ? 1 : 0] ?? editor.asset
      if (!editor.project.assets.some(item => item.id === asset && item.kind === 'practice')) throw new Error('Choose a raw practice take for its original passes')
      if (command === 'practice-passes') return { editor, effect: { kind: command, asset } }
      if (!/^[1-9][0-9]*$/.test(args[0])) throw new Error('Choose a positive original practice pass number')
      const region = selectedRegion(editor)
      return { editor, effect: { kind: command, asset, pass: args[0], tick: editor.tick, region: region?.asset === asset ? region.id : null } }
    }
    case 'edit-midi': {
      count(0, 2); const asset = args[0] ?? editor.asset
      if (!editor.project.assets.some(item => item.id === asset && item.kind === 'midi')) throw new Error('Choose a MIDI asset to edit')
      return { editor, effect: { kind: command, asset, pattern: args[1] === undefined ? asset === editor.asset ? editor.pattern : undefined : pattern(args[1]) } }
    }
    case 'record-calibration':
    case 'calibration-open':
      if (!tail) throw new Error('Choose a saved calibration experiment directory')
      return { editor, effect: { kind: command, path: tail } }
    case 'calibration-apply':
      count(1)
      if (!Number.isSafeInteger(Number(args[0])) || Number(args[0]) < 1) throw new Error('Choose a displayed calibration pulse number')
      return { editor, effect: { kind: command, match: Number(args[0]) - 1 } }
    case 'record-correction':
      if (args[0] === 'none') { count(1); return { editor, effect: { kind: command, action: 'clear' } } }
      if (args[0] === 'pulse') {
        count(2)
        if (!Number.isSafeInteger(Number(args[1])) || Number(args[1]) < 1) throw new Error('Choose a displayed calibration pulse number')
        return { editor, effect: { kind: command, action: 'measured', match: Number(args[1]) - 1 } }
      }
      if (args[0] === 'manual') {
        count(4)
        const audioChannel = { input: Number(args[2]), output: Number(args[3]) }
        if (!Object.values(audioChannel).every(n => Number.isSafeInteger(n) && n > 0 && n <= 0xffffffff)) throw new Error('Choose positive native input/output channel numbers')
        return { editor, effect: { kind: command, action: 'manual', audioChannel, placement: manualCapturePlacement(args[1]) } }
      }
      throw new Error('Choose record-correction none, manual MS IN OUT or pulse N')
    case 'split-take': count(0); value = { kind: 'capture-split', id: regionID(editor) }; break
    case 'capture-channel':
      if (selectedRegion(editor)?.component !== 'audio') throw new Error('Choose a separated audio component for channel routing')
      if (args.length === 1 && args[0] === 'all') value = { kind: 'region-change', id: regionID(editor), audioChannel: undefined }
      else { count(2); value = { kind: 'region-change', id: regionID(editor), audioChannel: { input: Number(args[0]), output: Number(args[1]) } } }
      break
    case 'capture-offset': count(1); value = { kind: 'region-change', id: regionID(editor), placement: manualCapturePlacement(args[0]) }; break
    case 'calibrate':
      count(4)
      return { editor, effect: { kind: command, ...calibrationSelection({ output: args[0], inputChannel: Number(args[1]), outputChannel: Number(args[2]), maxLagMs: Number(args[3]) }) } }
    case 'import-wave': case 'import-midi': case 'import-take': case 'import-practice': case 'save-as':
      if (!tail) throw new Error('Choose a file path')
      return { editor, effect: { kind: command, path: tail } }
    case 'open-take': {
      count(0, 1); const asset = args[0] ?? editor.asset
      if (!editor.project.assets.some(item => item.id === asset && item.kind === 'capture')) throw new Error('Choose a captured take')
      return { editor, effect: { kind: 'open-take', asset } }
    }
    case 'save': case 'help': case 'play': case 'play-audio': case 'stop':
    case 'inputs': case 'record': case 'record-stop': count(0); return { editor, effect: { kind: command } }
    case 'input': case 'midi-input': if (!tail) throw new Error('Choose an input UID'); return { editor, effect: { kind: command, input: tail } }
    case 'midi-monitor': {
      if (args.length === 1 && args[0] === 'off') return { editor, effect: { kind: command, action: 'clear' } }
      if (args[0] === 'remove') { count(3); return { editor, effect: { kind: command, action: 'remove', source: args[1], destination: args[2] } } }
      if (args.length < 2 || args.length % 2 !== 0) throw new Error('Use :midi-monitor SOURCE_UID DEST_UID [GROUP CHANNEL ...], or off')
      const channels = []
      for (let i = 2; i < args.length; i += 2) {
        const group = Number(args[i]), channel = Number(args[i + 1])
        if (![group, channel].every(n => Number.isInteger(n) && n >= 1 && n <= 16)) throw new Error('MIDI groups and channels start at 1 and end at 16')
        channels.push({ group: group - 1, channel: channel - 1 })
      }
      return { editor, effect: { kind: command, action: 'set', route: { source: args[0], destination: args[1], scope: channels.length ? { kind: 'channels', channels } : { kind: 'endpoint' } } } }
    }
    case 'monitor': if (!tail) throw new Error('Choose an audio output UID or off'); return { editor, effect: { kind: 'monitor', output: tail === 'off' ? null : tail } }
    case 'seek': count(1); return { editor, effect: { kind: 'seek', tick: position(beats(args[0])) } }
    case 'midi-output': count(1); return { editor, effect: { kind: command, destination: args[0] } }
    case 'midi-source': {
      count(3)
      const asset = editor.project.assets.find(asset => asset.id === args[0])
      const sources = asset?.kind === 'capture' ? asset.manifest.midiSources : asset?.kind === 'practice' ? [asset.metadata.input.source] : []
      if (!sources.some(source => source.id === args[1])) throw new Error('Choose a raw asset and its original MIDI source ID')
      if (!/^-?(0|[1-9][0-9]*)$/.test(args[2]) || BigInt(args[2]) < -2147483648n || BigInt(args[2]) > 2147483647n || String(Number(args[2])) !== args[2]) throw new Error('Choose an exact MIDI destination UID')
      return { editor, effect: { kind: command, asset: args[0], source: args[1], destination: args[2] } }
    }
    case 'midi-port': {
      count(3)
      if (!editor.project.assets.some(asset => asset.id === args[0] && asset.kind === 'midi')) throw new Error('Choose a MIDI asset')
      const port = Number(args[1])
      if (!Number.isInteger(port) || port < 0 || port > 127 || !/^-?(0|[1-9][0-9]*)$/.test(args[2])
          || BigInt(args[2]) < -2147483648n || BigInt(args[2]) > 2147483647n || String(Number(args[2])) !== args[2]) throw new Error('Choose an exact source port and destination UID')
      return { editor, effect: { kind: command, asset: args[0], port, destination: args[2] } }
    }
    case 'output': case 'mixed-output': if (!tail) throw new Error('Choose an output UID'); return { editor, effect: { kind: command, path: tail } }
    case 'wave':
      if (!tail) throw new Error('Use :wave /path/arrangement.wav')
      return { editor, effect: { kind: 'export-wave', path: tail } }
    case 'export':
      throw new Error('Arrangement MIDI export is not connected; use :wave FILE for audio')
    case 'asset': {
      count(1)
      if (!editor.project.assets.some(asset => asset.id === args[0])) throw new Error('Unknown arrangement asset')
      return { editor: { ...editor, asset: args[0], pattern: args[0] === editor.asset ? editor.pattern : undefined } }
    }
    case 'lane': count(1); return { editor: { ...editor, lane: ordinalLane(args[0]), region: null } }
    case 'select': {
      count(1); const clip = editor.project.clips.find(clip => clip.id === args[0])
      if (!clip) throw new Error('Unknown arrangement region')
      return { editor: { ...editor, region: clip.id, lane: clip.lane, asset: clip.asset, pattern: clip.pattern, tick: clip.position } }
    }
    case 'cursor': count(1); return { editor: { ...editor, tick: position(beats(args[0])) } }
    case 'grid': {
      count(1); const step = beats(args[0]); if (!step) throw new Error('Grid must be positive')
      return { editor: { ...editor, step } }
    }
    case 'place': count(2, 3); return { editor: place(editor, args[0], beats(args[1]), { pattern: pattern(args[2]) }) }
    case 'practice-region': {
      count(5, 6)
      if (!editor.project.assets.some(asset => asset.id === args[0] && asset.kind === 'practice')) throw new Error('Choose a raw practice source for fractional host cuts')
      return { editor: place(editor, args[0], beats(args[1]), { offset: args[2], extent: args[3], sourceDivisor: args[4], repeat: args[5] === undefined ? 1 : Number(args[5]) }) }
    }
    case 'trim-fraction': {
      count(3)
      if (editor.project.assets.find(asset => asset.id === selectedRegion(editor)?.asset)?.kind !== 'practice') throw new Error('Choose a practice region for fractional host cuts')
      value = { kind: 'region-change', id: regionID(editor), offset: args[0], extent: args[1], sourceDivisor: args[2] }; break
    }
    case 'capture-region': count(4, 5); return { editor: place(editor, args[0], beats(args[1]), {
      ...timeRange(args[0], args[2], args[3]), repeat: args[4] === undefined ? 1 : Number(args[4]) }) }
    case 'region': count(4, 6); return { editor: place(editor, args[0], beats(args[1]), {
      ...sourceRange(args[0], args[2], args[3]), repeat: args[4] === undefined ? 1 : Number(args[4]), pattern: pattern(args[5]) }) }
    case 'trim': count(2); value = { kind: 'region-change', id: regionID(editor), ...sourceRange(selectedRegion(editor)?.asset, args[0], args[1]) }; break
    case 'trim-time': count(2); value = { kind: 'region-change', id: regionID(editor), ...timeRange(selectedRegion(editor)?.asset, args[0], args[1]) }; break
    case 'repeat': count(1); value = { kind: 'region-change', id: regionID(editor), repeat: Number(args[0]) }; break
    case 'move': count(1); value = { kind: 'region-change', id: regionID(editor), position: beats(args[0]) }; break
    case 'region-lane': count(1); value = { kind: 'region-change', id: regionID(editor), lane: ordinalLane(args[0]) }; break
    case 'duplicate': count(1); return { editor: arrangementAction(editor, { kind: 'duplicate', tick: beats(args[0]) }) }
    case 'remove': case 'mute': case 'solo': case 'undo': case 'redo': count(0); return { editor: arrangementAction(editor, { kind: command }) }
    case 'lane-add': count(2, Number.MAX_SAFE_INTEGER); value = { kind: 'lane-add', sourceKind: args[0], name: args.slice(1).join(' ') }; break
    case 'lane-remove': count(0); value = { kind: 'lane-remove', id: laneID(editor) }; break
    case 'lane-name': if (!tail) throw new Error('Choose a lane name'); value = { kind: 'lane-name', id: laneID(editor), name: tail }; break
    case 'region-name': if (!tail) throw new Error('Choose a region name'); value = { kind: 'region-change', id: regionID(editor), name: tail }; break
    case 'title': if (!tail) throw new Error('Choose a title'); value = { kind: 'title', title: tail }; break
    case 'tempo': count(1); value = { kind: 'tempo', tempo: Number(args[0]) }; break
    case 'loop':
      if (args.length === 1 && args[0] === 'off') value = { kind: 'loop', range: null }
      else { count(2); value = { kind: 'loop', range: { start: beats(args[0]), end: beats(args[1]) } } }
      break
    case 'meter': count(2); value = { kind: 'meter', meter: args.map(Number) }; break
    default: throw new Error(`Unknown arrangement command: ${command}; use :help`)
  }
  const next = edit(editor, value)
  return { editor: command === 'lane-add' ? { ...next, lane: next.project.lanes.at(-1).id, region: null } : next }
}
