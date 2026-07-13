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
  phaseTokenFromKeeper,
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
  })
  it('maps transient phases to busy (working-through, not paused)', () => {
    // Fleet SSOT PHASE_TONE (lib/fleet-tone.ts) classifies the transient
    // FSM phases (Compacting / HandingOff / Restarting) as `busy` — the
    // blue rail, not the amber pause pill. They are operator-initiated
    // movement, not a stopped runtime.
    expect(keeperStatusTone(mk({ lifecycle_phase: 'Compacting' }))).toBe('busy')
    expect(keeperStatusTone(mk({ lifecycle_phase: 'HandingOff' }))).toBe('busy')
    expect(keeperStatusTone(mk({ lifecycle_phase: 'Restarting' }))).toBe('busy')
  })
  it('maps operator-initiated Draining to warn (not busy)', () => {
    // The prototype PHASE_TONE table treats Draining as `warn` (operator
    // intent via the `stop` action's danger:true via-phase), distinct
    // from the auto-movement busy phase. This is the P2 gap the
    // adversarial reviewer flagged: TRANSIENT_KEEPER_PHASES in
    // monitoring-runtime.ts includes Draining as a transient band, but
    // the workspace tone must follow the prototype's `warn` classification
    // so the rail does not paint an operator-initiated stop as "moving".
    expect(keeperStatusTone(mk({ lifecycle_phase: 'Draining' }))).toBe('warn')
  })
  it('maps operator-initiated pause to warn (amber, distinct from transient blue)', () => {
    expect(keeperStatusTone(mk({ status: 'running', paused: true }))).toBe('warn')
    expect(keeperStatusTone(mk({ lifecycle_phase: 'Paused', paused: true }))).toBe('warn')
  })
  it('maps stopped / unbooted to idle', () => {
    expect(keeperStatusTone(mk({ status: 'stopped' }))).toBe('idle')
    expect(keeperStatusTone(mk({ lifecycle_phase: 'Offline' }))).toBe('idle')
  })
  it('collapses unknown tokens to idle (closed-sum fallback)', () => {
    expect(keeperStatusTone(mk({ status: 'bootstrapping' }))).toBe('idle')
  })
})

describe('statePillTone', () => {
  it('maps health tones to pill modifier classes', () => {
    expect(statePillTone('ok')).toBe('run')
    expect(statePillTone('warn')).toBe('warn')
    expect(statePillTone('bad')).toBe('bad')
    expect(statePillTone('busy')).toBe('busy')
    expect(statePillTone('idle')).toBe('off')
  })
})

describe('keeperModelLabel', () => {
  it('does not expose raw keeper model fields', () => {
    expect(keeperModelLabel(mk({ active_model_label: 'A', active_model: 'B', model: 'C' }))).toBeNull()
    expect(keeperModelLabel(mk({ active_model: 'B', model: 'C' }))).toBeNull()
    expect(keeperModelLabel(mk({ model: 'C' }))).toBeNull()
    expect(keeperModelLabel(mk({}))).toBeNull()
  })
})

describe('keeperRuntimeLabel', () => {
  it('uses the shared runtime display priority', () => {
    expect(keeperRuntimeLabel(mk({ runtime_canonical: ' oas.seoul-1 ' }))).toBe('oas.seoul-1')
    expect(keeperRuntimeLabel(mk({ selected_runtime_canonical: 'local·docker' }))).toBe('local·docker')
    expect(keeperRuntimeLabel(mk({ runtime_id: 'keeper_unified' }))).toBe('keeper_unified')
    expect(keeperRuntimeLabel(mk({ runtime_ref: { group: 'tier', item: 'resilient_breaker' } }))).toBe('tier.resilient_breaker')
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
  it('collapses unknown tokens to the 알 수 없음 fallback (no raw wire string leak)', () => {
    // Closed-sum SSOT: phaseTokenFromKeeper returns 'unknown' for unmapped
    // wire tokens, and PHASE_LABEL_KO['unknown'] is the canonical
    // '알 수 없음' label. The old behavior leaked raw status strings
    // like 'bootstrapping' into the UI — that's a wire-format leak.
    expect(keeperPhaseLabel(mk({ status: 'bootstrapping' }))).toBe('알 수 없음')
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
    expect(el.textContent).toBe('MI')
    expect(el.style.background).toContain('--color-keeper-7') // based on new hash12
    expect(el.style.width).toBe('46px')
  })
})

describe('keeperFleetTone', () => {
  it('surfaces attention and approval gates as bad even when the keeper is running', () => {
    expect(keeperFleetTone(mk({ needs_attention: true }))).toBe('bad')
    expect(keeperFleetTone(mk({ blocked_task_count: 2 }))).toBe('bad')
    expect(keeperFleetTone(mk({ current_gate: { kind: 'approval_required', tool: 'shell' } }))).toBe('bad')
  })

  it('falls back to the canonical status tone when no fleet attention is present', () => {
    expect(keeperFleetTone(mk({ status: 'running', lifecycle_phase: 'Running' }))).toBe('ok')
    expect(keeperFleetTone(mk({ status: 'running', lifecycle_phase: 'Paused', paused: true }))).toBe('warn')
    expect(keeperFleetTone(mk({ status: 'running', lifecycle_phase: 'Compacting' }))).toBe('busy')
  })
})

describe('phaseTokenFromKeeper', () => {
  it('lowercases PascalCase lifecycle_phase to the closed token space', () => {
    expect(phaseTokenFromKeeper(mk({ lifecycle_phase: 'Compacting' }))).toBe('compacting')
    expect(phaseTokenFromKeeper(mk({ lifecycle_phase: 'HandingOff' }))).toBe('handoff')
    expect(phaseTokenFromKeeper(mk({ lifecycle_phase: 'Draining' }))).toBe('draining')
  })
  it('returns unknown for tokens outside the closed sum', () => {
    expect(phaseTokenFromKeeper(mk({ status: 'bootstrapping' }))).toBe('unknown')
  })
  it('rejects Object.prototype member names as wire tokens', () => {
    // Regression: the prior guard was `value in PHASE_TONE`, which walks
    // the prototype chain and accepts inherited property names like
    // `constructor`, `toString`, `__proto__`. A backend that emits one of
    // those strings (or any future JS reserved name) used to bypass the
    // `'unknown'` fallback and surface inherited members in
    // `keeperStatusTone` / `keeperPhaseLabel`. The new guard uses
    // own-property checks against a null-prototype map, so all of these
    // collapse to `'unknown'`.
    expect(phaseTokenFromKeeper(mk({ status: 'constructor' }))).toBe('unknown')
    expect(phaseTokenFromKeeper(mk({ status: 'toString' }))).toBe('unknown')
    expect(phaseTokenFromKeeper(mk({ status: '__proto__' }))).toBe('unknown')
    expect(phaseTokenFromKeeper(mk({ status: 'hasOwnProperty' }))).toBe('unknown')
    expect(phaseTokenFromKeeper(mk({ status: 'valueOf' }))).toBe('unknown')
  })
})
