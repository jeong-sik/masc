import { describe, expect, it } from 'vitest'

import {
  traceEventMatchesSearch,
  fmtPct,
  candidateTone,
  sourceLabel,
  sourceTone,
  providerTone,
  capacityTone,
  eventKindTone,
  eventKindLabel,
  capacityKindLabel,
  traceKindTone,
  traceKindLabel,
} from './cascade-config-panel'
import type {
  CascadeCandidate,
  CascadeClientCapacityEntry,
  CascadeHealthProvider,
  CascadeStrategyTraceEvent,
} from '../api/dashboard'

// --- Helpers ---

function makeTraceEvent(overrides: Partial<CascadeStrategyTraceEvent> = {}): CascadeStrategyTraceEvent {
  return {
    ts: Date.now() / 1000 - 60,
    cascade_name: 'default',
    strategy: 'weighted',
    cycle: 1,
    candidates_in: 3,
    candidates_out: 1,
    backoff_ms: 0,
    kind: 'ordered',
    ...overrides,
  }
}

function makeCandidate(overrides: Partial<CascadeCandidate> = {}): CascadeCandidate {
  return {
    model: 'test-model',
    config_weight: 1,
    effective_weight: 1,
    success_rate: 0.95,
    in_cooldown: false,
    ...overrides,
  }
}

function makeProvider(overrides: Partial<CascadeHealthProvider> = {}): CascadeHealthProvider {
  return {
    provider_key: 'test-provider',
    success_rate: 0.95,
    consecutive_failures: 0,
    events_in_window: 10,
    in_cooldown: false,
    cooldown_expires_at: null,
    ...overrides,
  }
}

function makeCapacityEntry(overrides: Partial<CascadeClientCapacityEntry> = {}): CascadeClientCapacityEntry {
  return {
    kind: 'cli',
    key: 'test-key',
    active: 1,
    available: 2,
    total: 3,
    ...overrides,
  }
}

// --- Tests ---

describe('fmtPct', () => {
  it('formats ratio as percentage string', () => {
    expect(fmtPct(0.955)).toBe('95.5%')
    expect(fmtPct(1.0)).toBe('100.0%')
  })

  it('returns -- for NaN', () => {
    expect(fmtPct(NaN)).toBe('--')
  })
})

describe('candidateTone', () => {
  it('returns bad for cooldown', () => {
    expect(candidateTone(makeCandidate({ in_cooldown: true }))).toBe('bad')
  })

  it('returns bad for zero effective weight', () => {
    expect(candidateTone(makeCandidate({ effective_weight: 0 }))).toBe('bad')
  })

  it('returns bad for very low success rate', () => {
    expect(candidateTone(makeCandidate({ success_rate: 0.3 }))).toBe('bad')
  })

  it('returns warn for moderate success rate', () => {
    expect(candidateTone(makeCandidate({ success_rate: 0.8 }))).toBe('warn')
  })

  it('returns ok for healthy candidate', () => {
    expect(candidateTone(makeCandidate())).toBe('ok')
  })
})

describe('sourceLabel', () => {
  it('maps source kinds', () => {
    expect(sourceLabel('named')).toBe('named')
    expect(sourceLabel('default_fallback')).toBe('default')
    expect(sourceLabel('hardcoded_defaults')).toBe('hardcoded')
  })
})

describe('sourceTone', () => {
  it('returns ok for named', () => {
    expect(sourceTone('named')).toBe('ok')
  })

  it('returns warn for fallbacks', () => {
    expect(sourceTone('default_fallback')).toBe('warn')
    expect(sourceTone('hardcoded_defaults')).toBe('warn')
  })
})

describe('providerTone', () => {
  it('returns bad for cooldown', () => {
    expect(providerTone(makeProvider({ in_cooldown: true }))).toBe('bad')
  })

  it('returns bad for low success rate', () => {
    expect(providerTone(makeProvider({ success_rate: 0.5 }))).toBe('bad')
  })

  it('returns warn for moderate success rate', () => {
    expect(providerTone(makeProvider({ success_rate: 0.8 }))).toBe('warn')
  })

  it('returns ok for healthy provider', () => {
    expect(providerTone(makeProvider())).toBe('ok')
  })
})

describe('capacityTone', () => {
  it('returns bad for zero total', () => {
    expect(capacityTone(makeCapacityEntry({ total: 0 }))).toBe('bad')
  })

  it('returns warn for zero available', () => {
    expect(capacityTone(makeCapacityEntry({ available: 0 }))).toBe('warn')
  })

  it('returns ok for healthy entry', () => {
    expect(capacityTone(makeCapacityEntry())).toBe('ok')
  })
})

describe('eventKindTone', () => {
  it('maps event kinds to tones', () => {
    expect(eventKindTone('acquired')).toBe('ok')
    expect(eventKindTone('released')).toBe('neutral')
    expect(eventKindTone('rejected_full')).toBe('bad')
  })
})

describe('eventKindLabel', () => {
  it('maps event kinds to labels', () => {
    expect(eventKindLabel('acquired')).toBe('acquired')
    expect(eventKindLabel('released')).toBe('released')
    expect(eventKindLabel('rejected_full')).toBe('rejected')
  })
})

describe('capacityKindLabel', () => {
  it('maps capacity kinds to labels', () => {
    expect(capacityKindLabel('cli')).toBe('CLI')
    expect(capacityKindLabel('ollama')).toBe('Ollama')
    expect(capacityKindLabel('other')).toBe('Other')
  })
})

describe('traceKindTone', () => {
  it('maps trace kinds to tones', () => {
    expect(traceKindTone('ordered')).toBe('ok')
    expect(traceKindTone('filtered_empty')).toBe('warn')
    expect(traceKindTone('exhausted')).toBe('bad')
  })
})

describe('traceKindLabel', () => {
  it('maps trace kinds to Korean labels', () => {
    expect(traceKindLabel('ordered')).toBe('정렬')
    expect(traceKindLabel('filtered_empty')).toBe('전부 차단')
    expect(traceKindLabel('exhausted')).toBe('소진')
  })
})

describe('traceEventMatchesSearch', () => {
  it('matches cascade_name', () => {
    const e = makeTraceEvent({ cascade_name: 'production-v2' })
    expect(traceEventMatchesSearch(e, 'production')).toBe(true)
    expect(traceEventMatchesSearch(e, 'v2')).toBe(true)
  })

  it('matches strategy', () => {
    const e = makeTraceEvent({ strategy: 'round-robin' })
    expect(traceEventMatchesSearch(e, 'round')).toBe(true)
    expect(traceEventMatchesSearch(e, 'robin')).toBe(true)
  })

  it('matches kind label (Korean)', () => {
    const e = makeTraceEvent({ kind: 'exhausted' })
    expect(traceEventMatchesSearch(e, '소진')).toBe(true)
  })

  it('matches kind value (English)', () => {
    const e = makeTraceEvent({ kind: 'filtered_empty' })
    expect(traceEventMatchesSearch(e, 'filtered')).toBe(true)
  })

  it('matches cycle number', () => {
    const e = makeTraceEvent({ cycle: 42 })
    expect(traceEventMatchesSearch(e, '42')).toBe(true)
  })

  it('matches candidates_in/out numbers', () => {
    const e = makeTraceEvent({ candidates_in: 5, candidates_out: 2 })
    expect(traceEventMatchesSearch(e, '5')).toBe(true)
  })

  it('is case-insensitive', () => {
    const e = makeTraceEvent({ cascade_name: 'Production' })
    expect(traceEventMatchesSearch(e, 'production')).toBe(true)
    expect(traceEventMatchesSearch(e, 'PRODUCTION')).toBe(true)
  })

  it('returns false when nothing matches', () => {
    const e = makeTraceEvent()
    expect(traceEventMatchesSearch(e, 'nonexistent-xyz')).toBe(false)
  })

  it('returns true for empty query (no filtering)', () => {
    const e = makeTraceEvent()
    expect(traceEventMatchesSearch(e, '')).toBe(true)
  })
})
