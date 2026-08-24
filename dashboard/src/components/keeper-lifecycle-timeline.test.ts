import { describe, it, expect, vi } from 'vitest'

// Mock modules with lucide-preact icons that cause test-env errors
vi.mock('../store', () => ({
  keepers: { value: [] },
}))
vi.mock('./common/feedback-state', () => ({ LoadingState: () => null }))
vi.mock('./common/time-ago', () => ({ TimeAgo: () => null }))
vi.mock('./keeper-phase-indicator', () => ({
  getPhaseStyle: () => ({ color: '', bg: '', border: '', icon: '', label: '' }),
}))
vi.mock('./keeper-phase-strip', () => ({ toPascalPhase: (s: string) => s }))
vi.mock('../api/keeper', () => ({
  fetchKeeperLifecycle: vi.fn(async () => ({ keeper: '', count: 0, events: [] })),
}))

import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import {
  lifecycleEventTone,
  lifecycleEventLabel,
  LIFECYCLE_VERBS,
} from './keeper-lifecycle-timeline'

// `Keeper_lifecycle_events.t` is the producer of every custom event name that
// reaches this timeline. Reading its `to_string` here keeps the TypeScript
// vocabulary from drifting when a verb is added or renamed on the OCaml side —
// the compiler already forces the tone and label maps to agree with each other,
// but it cannot see the wire producer.
const LIFECYCLE_EVENTS_ML = resolve(
  __dirname,
  '../../../lib/keeper_registry/keeper_lifecycle_events.ml',
)

function ocamlVerbs(): string[] {
  const source = readFileSync(LIFECYCLE_EVENTS_ML, 'utf-8')
  const start = source.indexOf('let to_string = function')
  expect(start).toBeGreaterThan(-1)
  const body = source.slice(start, source.indexOf('\n\n', start))
  return [...body.matchAll(/->\s*"([a-z_]+)"/g)].flatMap(m =>
    m[1] === undefined ? [] : [m[1]],
  )
}

describe('lifecycle vocabulary', () => {
  it('covers exactly the verbs Keeper_lifecycle_events emits', () => {
    expect([...LIFECYCLE_VERBS].sort()).toEqual(ocamlVerbs().sort())
  })

  it('gives every verb a label distinct from the raw wire name', () => {
    for (const verb of LIFECYCLE_VERBS) {
      expect(lifecycleEventLabel(verb)).not.toBe(verb.replace(/_/g, ' '))
    }
  })

  it('renders a refused launch as bad, not as muted info', () => {
    expect(lifecycleEventTone('admission_denied')).toBe('bad')
  })
})

describe('lifecycleEventTone', () => {
  it('started returns ok', () => {
    expect(lifecycleEventTone('started')).toBe('ok')
  })

  it('reconciled returns ok', () => {
    expect(lifecycleEventTone('reconciled')).toBe('ok')
  })

  it('restarted returns warn', () => {
    expect(lifecycleEventTone('restarted')).toBe('warn')
  })

  it('supervisor_cleaned returns neutral', () => {
    expect(lifecycleEventTone('supervisor_cleaned')).toBe('neutral')
  })

  it('purged returns info', () => {
    expect(lifecycleEventTone('purged')).toBe('info')
  })

  it('unknown events return info', () => {
    expect(lifecycleEventTone('unknown_event')).toBe('info')
    expect(lifecycleEventTone('')).toBe('info')
  })

  it('is case-insensitive via trim+toLowerCase', () => {
    expect(lifecycleEventTone('  Started  ')).toBe('ok')
    expect(lifecycleEventTone('RESTARTED')).toBe('warn')
  })
})

describe('lifecycleEventLabel', () => {
  it('maps started to Korean label', () => {
    expect(lifecycleEventLabel('started')).toBe('기동됨')
  })

  it('maps restarted to Korean label', () => {
    expect(lifecycleEventLabel('restarted')).toBe('재시작됨')
  })

  it('maps supervisor_cleaned to Korean label', () => {
    expect(lifecycleEventLabel('supervisor_cleaned')).toBe('부재 Keeper 정리됨')
  })

  it('maps admission_denied to Korean label', () => {
    expect(lifecycleEventLabel('admission_denied')).toBe('기동 거부됨')
  })

  it('maps purged to Korean label', () => {
    expect(lifecycleEventLabel('purged')).toBe('완전 삭제됨')
  })

  it('falls back to underscore-replaced string for unknown events', () => {
    expect(lifecycleEventLabel('my_custom_event')).toBe('my custom event')
  })

  it('returns empty string as-is', () => {
    expect(lifecycleEventLabel('')).toBe('')
  })
})
