import { render } from 'preact'
import { afterEach, describe, expect, it } from 'vitest'
import {
  keeperBucket,
  bucketDotTone,
  statePillTone,
  keeperModelLabel,
  keeperRuntimeLabel,
  keeperPhaseLabel,
  WorkspaceSigil,
} from './keeper-workspace-shared'
import { html } from 'htm/preact'
import type { Keeper } from '../../types'

function mk(partial: Partial<Keeper>): Keeper {
  return { name: 'k', status: 'running', ...partial } as Keeper
}

describe('keeperBucket', () => {
  it('classifies a running keeper', () => {
    expect(keeperBucket(mk({ status: 'running' }))).toBe('running')
  })
  it('classifies a paused keeper from the paused flag', () => {
    expect(keeperBucket(mk({ status: 'running', paused: true }))).toBe('paused')
  })
  it('classifies a stopped keeper as offline', () => {
    expect(keeperBucket(mk({ status: 'stopped' }))).toBe('offline')
  })
})

describe('bucketDotTone / statePillTone', () => {
  it('maps buckets to dot tones', () => {
    expect(bucketDotTone('running')).toBe('ok')
    expect(bucketDotTone('paused')).toBe('warn')
    expect(bucketDotTone('offline')).toBe('idle')
  })
  it('maps buckets to pill tones', () => {
    expect(statePillTone('running')).toBe('run')
    expect(statePillTone('paused')).toBe('warn')
    expect(statePillTone('offline')).toBe('off')
  })
})

describe('keeperModelLabel', () => {
  it('prefers active_model_label, then active_model, then model', () => {
    expect(keeperModelLabel(mk({ active_model_label: 'A', active_model: 'B', model: 'C' }))).toBe('A')
    expect(keeperModelLabel(mk({ active_model: 'B', model: 'C' }))).toBe('B')
    expect(keeperModelLabel(mk({ model: 'C' }))).toBe('C')
    expect(keeperModelLabel(mk({}))).toBeNull()
  })
})

describe('keeperRuntimeLabel', () => {
  it('prefers runtime_canonical then selected_runtime_canonical', () => {
    expect(keeperRuntimeLabel(mk({ runtime_canonical: 'oas·seoul-1' }))).toBe('oas·seoul-1')
    expect(keeperRuntimeLabel(mk({ selected_runtime_canonical: 'local·docker' }))).toBe('local·docker')
    expect(keeperRuntimeLabel(mk({}))).toBeNull()
  })
})

describe('keeperPhaseLabel', () => {
  it('prefers the typed lifecycle phase', () => {
    expect(keeperPhaseLabel(mk({ lifecycle_phase: 'Running' }))).toBe('Running')
    expect(keeperPhaseLabel(mk({ phase: 'Compacting' }))).toBe('Compacting')
  })
})

describe('WorkspaceSigil', () => {
  let host: HTMLElement
  afterEach(() => {
    if (host) render(null, host)
  })
  it('renders the 2-letter sigil with the keeper color slot', () => {
    host = document.createElement('div')
    render(html`<${WorkspaceSigil} id="masc-improver" size=${46} />`, host)
    const el = host.querySelector('.kw-sigil') as HTMLElement
    expect(el).toBeTruthy()
    expect(el.textContent).toBe('MS') // canonical sigil for masc-improver
    expect(el.style.background).toContain('--color-keeper-6') // canonical slot 6
    expect(el.style.width).toBe('46px')
  })
})
