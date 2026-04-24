import { describe, expect, it } from 'vitest'

import {
  traceEventMatchesSearch,
  filterHealthProviders,
  fmtPct,
  candidateTone,
  catalogSourceSummary,
  sourceLabel,
  sourceTone,
  providerTone,
  providerStatusTone,
  fmtPerfTokPerSec,
  fmtPerfLatencyPair,
  capacityTone,
  eventKindTone,
  eventKindLabel,
  capacityKindLabel,
  traceKindTone,
  traceKindLabel,
  groupKeepersByCanonicalCascade,
  keepersWithUnknownCanonical,
  profileSummaryText,
  profileKeeperAssignmentNote,
  availableKeeperAssignments,
  rawConfigModeSummary,
  validateSourceConfigText,
} from './cascade-config-panel'
import type {
  CascadeCandidate,
  CascadeClientCapacityEntry,
  CascadeConfigResponse,
  CascadeHealthProvider,
  CascadeKeeperProfile,
  CascadeProfile,
  CascadeRawConfigResponse,
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

function makeCascadeConfig(overrides: Partial<CascadeConfigResponse> = {}): CascadeConfigResponse {
  return {
    updated_at: '2026-04-22T08:00:00Z',
    config_path: '/tmp/config/cascade.json',
    source_kind: 'json',
    source_path: '/tmp/config/cascade.json',
    validation_status: 'validated',
    validation_errors: [],
    invalid_profiles: [],
    profiles: [],
    keeper_profiles: [],
    ...overrides,
  }
}

function makeRawConfig(
  overrides: Partial<CascadeRawConfigResponse> = {},
): CascadeRawConfigResponse {
  return {
    updated_at: '2026-04-22T08:00:00Z',
    config_path: '/tmp/config/cascade.json',
    source_kind: 'json',
    source_path: '/tmp/config/cascade.json',
    source_editable: true,
    source_text: '{}',
    raw_json_editable: true,
    raw_json: '{}',
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

describe('catalogSourceSummary', () => {
  it('explains TOML as SSOT and JSON as generated artifact', () => {
    const summary = catalogSourceSummary(
      makeCascadeConfig({
        source_kind: 'toml',
        source_path: '/tmp/config/cascade.toml',
        config_path: '/tmp/config/cascade.json',
      }),
    )
    expect(summary).toContain('SSOT:')
    expect(summary).toContain('/tmp/config/cascade.toml')
    expect(summary).toContain('/tmp/config/cascade.json')
    expect(summary).toContain('generated')
  })

  it('explains JSON mode as direct runtime edit', () => {
    const summary = catalogSourceSummary(makeCascadeConfig())
    expect(summary).toContain('direct runtime edit')
    expect(summary).toContain('/tmp/config/cascade.json')
  })
})

describe('rawConfigModeSummary', () => {
  it('marks TOML-backed config as editable source plus generated preview', () => {
    const summary = rawConfigModeSummary(
      makeRawConfig({
        source_kind: 'toml',
        source_path: '/tmp/config/cascade.toml',
        raw_json_editable: false,
      }),
    )
    expect(summary.title).toContain('TOML SSOT')
    expect(summary.primary).toContain('/tmp/config/cascade.toml')
    expect(summary.primary).toContain('cascade.toml SSOT')
    expect(summary.secondary).toContain('/tmp/config/cascade.json')
    expect(summary.saveLabel).toBe('Save cascade.toml')
    expect(summary.previewTitle).toBe('Generated cascade.json Preview')
  })

  it('keeps JSON mode editable', () => {
    const summary = rawConfigModeSummary(makeRawConfig())
    expect(summary.title).toBe('Active Cascade Source Editor')
    expect(summary.primary).toContain('/tmp/config/cascade.json')
    expect(summary.saveLabel).toBe('Save cascade.json')
    expect(summary.previewTitle).toBeNull()
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

describe('providerStatusTone', () => {
  it('maps active to ok', () => {
    expect(providerStatusTone('active')).toBe('ok')
  })
  it('maps cooldown to bad', () => {
    expect(providerStatusTone('cooldown')).toBe('bad')
  })
  it('maps configured to neutral', () => {
    // A declared-but-untouched provider is informational, not warning —
    // the operator chose to declare it and traffic simply has not hit
    // it yet. Rendering as `warn` would flag every dormant candidate
    // as a problem.
    expect(providerStatusTone('configured')).toBe('neutral')
  })
  it('defaults undefined (pre-0.173 server) to neutral', () => {
    expect(providerStatusTone(undefined)).toBe('neutral')
  })
})

describe('fmtPerfTokPerSec', () => {
  it('renders "—" for undefined (field absent on older server)', () => {
    expect(fmtPerfTokPerSec(undefined)).toBe('—')
  })
  it('renders "no data" for null (aggregator ran, nothing reported)', () => {
    // The distinction matters: "—" tells the operator "this server
    // does not know about perf" while "no data" tells them "the server
    // looked but no contributing model reported the field"
    // (Anthropic/Gemini path).
    expect(fmtPerfTokPerSec(null)).toBe('no data')
  })
  it('renders a numeric value to one decimal', () => {
    expect(fmtPerfTokPerSec(42.678)).toBe('42.7')
  })
  it('does not collapse zero to a dash', () => {
    expect(fmtPerfTokPerSec(0)).toBe('0.0')
  })
})

describe('fmtPerfLatencyPair', () => {
  it('renders both values as rounded integers with ms suffix', () => {
    expect(fmtPerfLatencyPair(1500.6, 3200.4)).toBe('1501 / 3200 ms')
  })
  it('uses "—" for undefined and "ø" for null inside the pair', () => {
    expect(fmtPerfLatencyPair(undefined, undefined)).toBe('— / — ms')
    expect(fmtPerfLatencyPair(null, null)).toBe('ø / ø ms')
    expect(fmtPerfLatencyPair(1500, null)).toBe('1500 / ø ms')
  })
  it('renders zero as 0 (not a dash)', () => {
    expect(fmtPerfLatencyPair(0, 0)).toBe('0 / 0 ms')
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
    return { name, source: 'named', keeper_assignable: true, candidates: [] }
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

describe('profileSummaryText', () => {
  function makeProfile(overrides: Partial<CascadeProfile> = {}): CascadeProfile {
    return {
      name: 'keeper_unified',
      source: 'named',
      keeper_assignable: true,
      candidates: [],
      ...overrides,
    }
  }

  function makeKeeperRow(overrides: Partial<CascadeKeeperProfile> = {}): CascadeKeeperProfile {
    return {
      keeper: 'alice',
      cascade_name: 'keeper_unified',
      canonical: 'keeper_unified',
      ...overrides,
    }
  }

  it('shows keeper count for assignable profiles', () => {
    const profile = makeProfile({ candidates: [makeCandidate()] })
    const keepers = groupKeepersByCanonicalCascade([makeKeeperRow()]).get('keeper_unified') ?? []
    expect(profileSummaryText(profile, keepers)).toBe('1 candidate · 1 keeper')
  })

  it('omits zero-keeper count for manual/system-only profiles', () => {
    const profile = makeProfile({
      name: 'kimi_glm_local_mlx_vlm',
      keeper_assignable: false,
      candidates: [makeCandidate(), makeCandidate(), makeCandidate()],
    })
    expect(profileSummaryText(profile, [])).toBe('3 candidates')
  })
})

describe('profileKeeperAssignmentNote', () => {
  function makeProfile(overrides: Partial<CascadeProfile> = {}): CascadeProfile {
    return {
      name: 'keeper_unified',
      source: 'named',
      keeper_assignable: true,
      candidates: [],
      ...overrides,
    }
  }

  const assignedKeepers = groupKeepersByCanonicalCascade([
    {
      keeper: 'alice',
      cascade_name: 'keeper_unified',
      canonical: 'keeper_unified',
    },
  ]).get('keeper_unified') ?? []

  it('explains manual/system-only profiles without keepers', () => {
    const profile = makeProfile({ keeper_assignable: false })
    expect(profileKeeperAssignmentNote(profile, [])).toBe(
      'manual/system-only profile; not assigned to keepers by design',
    )
  })

  it('keeps no-keepers warning for assignable profiles', () => {
    expect(profileKeeperAssignmentNote(makeProfile(), [])).toBe('no keepers assigned')
  })

  it('surfaces drift when manual/system-only profile still has keepers', () => {
    const profile = makeProfile({ keeper_assignable: false })
    expect(profileKeeperAssignmentNote(profile, assignedKeepers)).toBe(
      'manual/system-only profile; current keepers still reference it',
    )
  })
})

describe('availableKeeperAssignments', () => {
  const assigned = groupKeepersByCanonicalCascade([
    {
      keeper: 'alice',
      cascade_name: 'keeper_unified',
      canonical: 'keeper_unified',
    },
  ]).get('keeper_unified') ?? []

  it('returns sorted keepers not already assigned to the profile', () => {
    expect(availableKeeperAssignments(['carol', 'alice', 'bob'], assigned)).toEqual([
      'bob',
      'carol',
    ])
  })

  it('deduplicates repeated keeper names', () => {
    expect(availableKeeperAssignments(['bob', 'bob', 'alice'], assigned)).toEqual(['bob'])
  })
})

describe('validateSourceConfigText', () => {
  it('validates JSON source client-side', () => {
    expect(validateSourceConfigText(makeRawConfig(), '{ invalid')).not.toBeNull()
  })

  it('skips client-side syntax validation for TOML source', () => {
    expect(
      validateSourceConfigText(
        makeRawConfig({ source_kind: 'toml', source_path: '/tmp/config/cascade.toml' }),
        '[broken',
      ),
    ).toBeNull()
  })
})
