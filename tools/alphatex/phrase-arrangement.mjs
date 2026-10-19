import { newProject, validateProject } from './sequencer-project.mjs'
import { projectMidi } from './sequencer-files.mjs'
import { importMidiSource, exportMidiSource, validateMidiSource, midiSourcePattern, tempoEvent } from './midi-source.mjs'
import { newArrangement, validateArrangement, arrangementID, editArrangement } from './arrangement.mjs'

// A generated phrase retains its editable draft beside its immutable wire
// snapshot. IO/preparation boundaries verify the relationship off the UI path.
export function verifyPhraseSnapshot(asset) {
  if (asset.phrase === undefined) return
  if (asset.kind !== 'midi' || asset.phrase.kind !== undefined) throw new Error('Invalid editable phrase snapshot')
  validateProject(asset.phrase)
  if (!Buffer.from(projectMidi(asset.phrase)).equals(Buffer.from(exportMidiSource(asset.source)))) {
    throw new Error('Editable phrase and MIDI snapshot disagree')
  }
}
export function phraseDocument(project, assetID) {
  validateArrangement(project)
  if (assetID === undefined) return newProject()
  const asset = project.assets.find(asset => asset.id === assetID && asset.kind === 'midi')
  if (!asset) throw new Error('Choose a MIDI asset to edit')
  verifyPhraseSnapshot(asset)
  return structuredClone(asset.phrase ?? asset.source)
}
export function importPhraseDocument(project, document) {
  validateArrangement(project)
  let source, phrase
  if (document?.kind === 'midi-source') source = structuredClone(validateMidiSource(document))
  else {
    if (document?.kind !== undefined) throw new Error('Choose a phrase or original MIDI document')
    phrase = structuredClone(validateProject(document))
    source = importMidiSource(projectMidi(phrase), { name: phrase.title })
  }
  const asset = { kind: 'midi', id: arrangementID(project.assets, 'asset'), name: phrase ? phrase.title : source.name, source,
    ...(phrase ? { phrase } : {}) }
  return { project: editArrangement(project, { kind: 'asset-add', asset }), asset: asset.id }
}
export function arrangementFromPhrase(phrase) {
  if (phrase?.kind !== undefined) throw new Error('Create an arrangement from an editable phrase; import source MIDI in the arrangement editor')
  validateProject(phrase)
  let project = { ...newArrangement({ title: phrase.title, tempo: phrase.tempo }), meter: [...phrase.meter] }
  const imported = importPhraseDocument(project, phrase); project = imported.project
  project = editArrangement(project, { kind: 'lane-add', sourceKind: 'midi', name: phrase.title })
  const source = project.assets[0].source, performance = midiSourcePattern(source)
  project = editArrangement(project, { kind: 'region-add', lane: project.lanes[0].id, asset: imported.asset,
    name: phrase.title, position: 0, offset: 0, extent: performance.ticks, repeat: 1 })
  return { project, asset: imported.asset }
}

// Keep the original performance (tempo map, expression, channels and SMF2
// pattern) in its own source clock. Project beats only locate the whole clip.
export function arrangementFromMidiSource(document, { pattern } = {}) {
  validateMidiSource(document)
  const performance = midiSourcePattern(document, { pattern })
  const tempo = performance.events.filter(event => event.kind === 'meta' && event.type === 0x51 && event.tick === 0).at(-1)
  const meter = performance.events.find(event => event.kind === 'meta' && event.type === 0x58 && event.tick === 0 && event.data.length === 4)
  let project = { ...newArrangement({ title: document.name, tempo: tempo ? tempoEvent(tempo).value : 120 }),
    meter: meter ? [meter.data[0], 2 ** meter.data[1]] : [4, 4] }
  const imported = importPhraseDocument(project, document); project = imported.project
  project = editArrangement(project, { kind: 'lane-add', sourceKind: 'midi', name: document.name })
  project = editArrangement(project, { kind: 'region-add', lane: project.lanes[0].id, asset: imported.asset,
    name: document.name, position: 0, offset: 0, extent: performance.ticks, repeat: 1,
    ...(performance.format === 2 ? { pattern: performance.pattern } : {}) })
  return { project, asset: imported.asset }
}
