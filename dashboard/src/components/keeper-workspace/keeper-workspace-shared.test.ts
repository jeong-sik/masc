import { render } from 'preact'
import { afterEach, describe, expect, it } from 'vitest'
import {
  keeperBucket,
  keeperFleetTone,
  keeperStatusTone,
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
  it('keeps an explicit pause state ahead of stale offline status', () => {
    expect(keeperBucket(mk({ status: 'stopped', paused: true }))).toBe('paused')
    expect(keeperBucket(mk({ status: 'offline', lifecycle_phase: 'Paused' }))).toBe('paused')
  })
  it('classifies a stopped keeper as offline', () => {
    expect(keeperBucket(mk({ status: 'stopped' }))).toBe('offline')
  })
})

describe('keeperStatusTone', () => {
  it('maps a running keeper to ok', () => {
    expect(keeperStatusTone(mk({ status: 'running' }))).toBe('ok')
  })
  it('surfaces error phases as bad (not a healthy green dot)', () => {
    // Failing/Overflowed are neither offline nor paused, so keeperBucket
    // classifies them as "running"; the tone must still flag them.
    expect(keeperStatusTone(mk({ lifecycle_phase: 'Failing' }))).toBe('bad')
    expect(keeperStatusTone(mk({ lifecycle_phase: 'Overflowed' }))).toBe('bad')
    expect(keeperStatusTone(mk({ lifecycle_phase: 'Crashed' }))).toBe('bad')
    expect(keeperStatusTone(mk({ lifecycle_phase: 'Dead' }))).toBe('bad')
    expect(keeperStatusTone(mk({ lifecycle_phase: 'Zombie' }))).toBe('bad')
  })
  it('maps transient phases to info (working-through, not paused)', () => {
    // Prototype fleet.jsx vocabulary distinguishes paused(warn) from
    // transient(info). Compacting / HandingOff / Draining / Restarting are
    // mid-phase movement, not operator-initiated pause — they render blue.
    expect(keeperStatusTone(mk({ lifecycle_phase: 'Compacting' }))).toBe('info')
    expect(keeperStatusTone(mk({ lifecycle_phase: 'HandingOff' }))).toBe('info')
    expect(keeperStatusTone(mk({ lifecycle_phase: 'Draining' }))).toBe('info')
    expect(keeperStatusTone(mk({ lifecycle_phase: 'Restarting' }))).toBe('info')
  })
  it('maps operator-initiated pause to warn (amber, distinct from transient blue)', () => {
    expect(keeperStatusTone(mk({ status: 'running', paused: true }))).toBe('warn')
    expect(keeperStatusTone(mk({ lifecycle_phase: 'Paused', paused: true }))).toBe('warn')
  })
  it('maps stopped / unbooted to idle', () => {
    expect(keeperStatusTone(mk({ status: 'stopped' }))).toBe('idle')
    expect(keeperStatusTone(mk({ lifecycle_phase: 'Offline' }))).toBe('idle')
  })
})

describe('statePillTone', () => {
  it('maps health tones to pill modifier classes', () => {
    expect(statePillTone('ok')).toBe('run')
    expect(statePillTone('warn')).toBe('warn')
    expect(statePillTone('bad')).toBe('bad')
    expect(statePillTone('info')).toBe('info')
    expect(statePillTone('idle')).toBe('off')
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
  it('maps the FSM phase to a Korean label (no raw PascalCase enum leak)', () => {
    expect(keeperPhaseLabel(mk({ lifecycle_phase: 'Running' }))).toBe('실행 중')
    expect(keeperPhaseLabel(mk({ lifecycle_phase: 'Compacting' }))).toBe('압축 중')
    expect(keeperPhaseLabel(mk({ lifecycle_phase: 'Failing' }))).toBe('오류 발생')
    expect(keeperPhaseLabel(mk({ lifecycle_phase: 'HandingOff' }))).toBe('인계 중')
  })
  it('falls back to the status token when no friendly label exists', () => {
    // keeperDisplayStatus returns the raw status string for unmapped tokens.
    expect(keeperPhaseLabel(mk({ status: 'bootstrapping' }))).toBe('bootstrapping')
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

describe('keeperFleetTone', () => {
  it('surfaces attention and approval gates as bad even when the keeper is running', () => {
    expect(keeperFleetTone(mk({ needs_attention: true }))).toBe('bad')
    expect(keeperFleetTone(mk({ blocked_task_count: 2 }))).toBe('bad')
    expect(keeperFleetTone(mk({ current_gate: { kind: 'approval_required', tool: 'shell', risk: 'high' } }))).toBe('bad')
  })

  it('falls back to the canonical status tone when no fleet attention is present', () => {
    expect(keeperFleetTone(mk({ status: 'running', lifecycle_phase: 'Running' }))).toBe('ok')
    expect(keeperFleetTone(mk({ status: 'running', lifecycle_phase: 'Paused', paused: true }))).toBe('warn')
  })
})
