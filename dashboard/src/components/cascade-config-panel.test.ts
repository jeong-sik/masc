import { describe, expect, it } from 'vitest'

import {
  traceEventMatchesSearch,
  filterHealthProviders,
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
  groupKeepersByCanonicalCascade,
  keepersWithUnknownCanonical,
} from './cascade-config-panel'
import type {
  CascadeCandidate,
  CascadeClientCapacityEntry,
  CascadeHealthProvider,
  CascadeKeeperProfile,
  CascadeProfile,
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

describe('filterHealthProviders', () => {
  it('returns input reference unchanged for empty query', () => {
    const providers = [makeProvider({ provider_key: 'groq' })]
    expect(filterHealthProviders(providers, '')).toBe(providers)
  })

  it('returns input reference unchanged for whitespace-only query', () => {
    const providers = [makeProvider({ provider_key: 'groq' })]
    expect(filterHealthProviders(providers, '   ')).toBe(providers)
  })

  it('trims the query before matching', () => {
    const providers = [
      makeProvider({ provider_key: 'groq-llama' }),
      makeProvider({ provider_key: 'ollama-local' }),
    ]
    const result = filterHealthProviders(providers, '  groq  ')
    expect(result).toHaveLength(1)
    expect(result[0]?.provider_key).toBe('groq-llama')
  })

  it('is case-insensitive on provider_key', () => {
    const providers = [makeProvider({ provider_key: 'Groq-LLaMA' })]
    expect(filterHealthProviders(providers, 'groq')).toHaveLength(1)
    expect(filterHealthProviders(providers, 'LLAMA')).toHaveLength(1)
  })

  it('matches substring in provider_key', () => {
    const providers = [
      makeProvider({ provider_key: 'anthropic-claude' }),
      makeProvider({ provider_key: 'openai-gpt4' }),
      makeProvider({ provider_key: 'groq-llama' }),
    ]
    const result = filterHealthProviders(providers, 'gpt')
    expect(result).toHaveLength(1)
    expect(result[0]?.provider_key).toBe('openai-gpt4')
  })

  it('matches "cooldown" keyword when provider is in cooldown', () => {
    const providers = [
      makeProvider({ provider_key: 'groq', in_cooldown: false }),
      makeProvider({ provider_key: 'openai', in_cooldown: true }),
    ]
    const result = filterHealthProviders(providers, 'cooldown')
    expect(result).toHaveLength(1)
    expect(result[0]?.provider_key).toBe('openai')
  })

  it('does not match "cooldown" keyword for providers not in cooldown', () => {
    const providers = [
      makeProvider({ provider_key: 'groq', in_cooldown: false }),
    ]
    expect(filterHealthProviders(providers, 'cooldown')).toHaveLength(0)
  })

  it('returns empty array when nothing matches', () => {
    const providers = [
      makeProvider({ provider_key: 'groq' }),
      makeProvider({ provider_key: 'openai' }),
    ]
    expect(filterHealthProviders(providers, 'nonexistent-xyz')).toHaveLength(0)
  })

  it('returns empty array for empty input even with query', () => {
    expect(filterHealthProviders([], 'groq')).toHaveLength(0)
  })

  it('does not mutate the input array', () => {
    const providers = [
      makeProvider({ provider_key: 'groq' }),
      makeProvider({ provider_key: 'openai' }),
    ]
    const before = providers.map(p => p.provider_key)
    filterHealthProviders(providers, 'groq')
    expect(providers.map(p => p.provider_key)).toEqual(before)
    expect(providers).toHaveLength(2)
  })
})

describe('groupKeepersByCanonicalCascade', () => {
  function makeKeeperProfile(overrides: Partial<CascadeKeeperProfile> = {}): CascadeKeeperProfile {
    return {
      keeper: 'alice',
      cascade_name: 'keeper_unified',
      canonical: 'keeper_unified',
      ...overrides,
    }
  }

  it('groups keepers by canonical name, collapsing legacy aliases', () => {
    const keepers = [
      makeKeeperProfile({ keeper: 'alice', cascade_name: 'keeper_unified' }),
      makeKeeperProfile({
        keeper: 'bob',
        cascade_name: 'oas-keeper_unified',
        canonical: 'keeper_unified',
      }),
      makeKeeperProfile({ keeper: 'carol', cascade_name: 'sangsu', canonical: 'sangsu' }),
    ]
    const groups = groupKeepersByCanonicalCascade(keepers)
    expect(groups.get('keeper_unified')?.map(r => r.keeper)).toEqual(['alice', 'bob'])
    expect(groups.get('sangsu')?.map(r => r.keeper)).toEqual(['carol'])
  })

  it('marks drift=true when raw differs from canonical', () => {
    const keepers = [
      makeKeeperProfile({
        keeper: 'bob',
        cascade_name: 'oas-keeper_unified',
        canonical: 'keeper_unified',
      }),
      makeKeeperProfile({
        keeper: 'alice',
        cascade_name: 'keeper_unified',
        canonical: 'keeper_unified',
      }),
    ]
    const rows = groupKeepersByCanonicalCascade(keepers).get('keeper_unified') ?? []
    expect(rows.find(r => r.keeper === 'bob')?.drift).toBe(true)
    expect(rows.find(r => r.keeper === 'alice')?.drift).toBe(false)
  })

  it('returns an empty Map for empty input', () => {
    expect(groupKeepersByCanonicalCascade([]).size).toBe(0)
  })

  it('does not mutate input array', () => {
    const keepers = [makeKeeperProfile()]
    const snapshot = JSON.stringify(keepers)
    groupKeepersByCanonicalCascade(keepers)
    expect(JSON.stringify(keepers)).toBe(snapshot)
  })
})

describe('keepersWithUnknownCanonical', () => {
  function makeProfile(name: string): CascadeProfile {
    return { name, source: 'named', candidates: [] }
  }
  function makeKeeperProfile(overrides: Partial<CascadeKeeperProfile> = {}): CascadeKeeperProfile {
    return {
      keeper: 'alice',
      cascade_name: 'keeper_unified',
      canonical: 'keeper_unified',
      ...overrides,
    }
  }

  it('returns empty when every canonical maps to a declared profile', () => {
    const profiles = [makeProfile('keeper_unified'), makeProfile('sangsu')]
    const keepers = [
      makeKeeperProfile({ keeper: 'alice', canonical: 'keeper_unified' }),
      makeKeeperProfile({ keeper: 'bob', canonical: 'sangsu' }),
    ]
    expect(keepersWithUnknownCanonical(profiles, keepers)).toEqual([])
  })

  it('returns only orphans when some canonical is not declared', () => {
    const profiles = [makeProfile('keeper_unified')]
    const keepers = [
      makeKeeperProfile({ keeper: 'alice', canonical: 'keeper_unified' }),
      makeKeeperProfile({ keeper: 'bob', canonical: 'ghost_cascade' }),
    ]
    const orphans = keepersWithUnknownCanonical(profiles, keepers)
    expect(orphans.map(o => o.keeper)).toEqual(['bob'])
  })
})
