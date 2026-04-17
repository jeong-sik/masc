import { describe, it, expect } from 'vitest'
import {
  providerTone,
  modelMetricTone,
  fmtCost,
  fmtSuccessRate,
  fmtNumber,
  filterProviders,
  filterModels,
} from './runtime-monitor'
import type { DashboardRuntimeProviderSnapshot, DashboardRuntimeModelMetric } from '../api/dashboard'

function makeProvider(overrides: Partial<DashboardRuntimeProviderSnapshot> = {}): DashboardRuntimeProviderSnapshot {
  return {
    provider: 'test-provider',
    models: [],
    ...overrides,
  }
}

function makeMetric(overrides: Partial<DashboardRuntimeModelMetric> = {}): DashboardRuntimeModelMetric {
  return {
    model_id: 'test-model',
    ...overrides,
  }
}

// ── providerTone ──

describe('providerTone', () => {
  it('returns bad when available is false', () => {
    expect(providerTone(makeProvider({ available: false }))).toBe('bad')
  })

  it('returns warn when discovery is not healthy', () => {
    expect(providerTone(makeProvider({ available: true, discovery: { healthy: false } }))).toBe('warn')
  })

  it('returns ok when available is true and healthy', () => {
    expect(providerTone(makeProvider({ available: true, discovery: { healthy: true } }))).toBe('ok')
  })

  it('returns ok when available is true without discovery', () => {
    expect(providerTone(makeProvider({ available: true }))).toBe('ok')
  })

  it('returns warn when available is undefined', () => {
    expect(providerTone(makeProvider())).toBe('warn')
  })

  it('returns warn when available is true but discovery is null', () => {
    expect(providerTone(makeProvider({ available: true, discovery: null }))).toBe('ok')
  })
})

// ── modelMetricTone ──

describe('modelMetricTone', () => {
  it('returns warn when entry_count is 0', () => {
    expect(modelMetricTone(makeMetric({ entry_count: 0 }))).toBe('warn')
  })

  it('returns warn when entry_count is undefined', () => {
    expect(modelMetricTone(makeMetric())).toBe('warn')
  })

  it('returns bad when success rate below 85%', () => {
    expect(modelMetricTone(makeMetric({ entry_count: 100, success_count: 80, error_count: 20 }))).toBe('bad')
  })

  it('returns warn when success rate between 85-95%', () => {
    expect(modelMetricTone(makeMetric({ entry_count: 100, success_count: 90, error_count: 10 }))).toBe('warn')
  })

  it('returns ok when success rate above 95%', () => {
    expect(modelMetricTone(makeMetric({ entry_count: 100, success_count: 96, error_count: 4 }))).toBe('ok')
  })

  it('returns warn when fallback_count > 0', () => {
    expect(modelMetricTone(makeMetric({ entry_count: 10, success_count: 10, error_count: 0, fallback_count: 1 }))).toBe('warn')
  })

  it('returns ok when all good and no fallbacks', () => {
    expect(modelMetricTone(makeMetric({ entry_count: 10, success_count: 10, error_count: 0, fallback_count: 0 }))).toBe('ok')
  })

  it('uses entry_count as fallback for success_count', () => {
    expect(modelMetricTone(makeMetric({ entry_count: 10, error_count: 0 }))).toBe('ok')
  })
})

// ── fmtCost ──

describe('fmtCost', () => {
  it('returns -- for undefined', () => {
    expect(fmtCost(undefined)).toBe('--')
  })

  it('returns -- for null', () => {
    expect(fmtCost(null)).toBe('--')
  })

  it('returns -- for NaN', () => {
    expect(fmtCost(NaN)).toBe('--')
  })

  it('returns $0 for zero', () => {
    expect(fmtCost(0)).toBe('$0')
  })

  it('formats small values with 4 decimals', () => {
    expect(fmtCost(0.005)).toBe('$0.0050')
  })

  it('formats regular values with 2 decimals', () => {
    expect(fmtCost(1.5)).toBe('$1.50')
  })

  it('formats large values with 2 decimals', () => {
    expect(fmtCost(123.456)).toBe('$123.46')
  })
})

// ── fmtSuccessRate ──

describe('fmtSuccessRate', () => {
  it('returns -- when total is 0', () => {
    expect(fmtSuccessRate(makeMetric({ success_count: 0, error_count: 0 }))).toBe('--')
  })

  it('returns -- when counts are undefined', () => {
    expect(fmtSuccessRate(makeMetric())).toBe('--')
  })

  it('formats 100% success', () => {
    expect(fmtSuccessRate(makeMetric({ success_count: 100, error_count: 0 }))).toBe('100.0%')
  })

  it('formats partial success', () => {
    expect(fmtSuccessRate(makeMetric({ success_count: 75, error_count: 25 }))).toBe('75.0%')
  })

  it('uses entry_count as fallback for success_count', () => {
    expect(fmtSuccessRate(makeMetric({ entry_count: 50, error_count: 0 }))).toBe('100.0%')
  })
})

// ── fmtNumber ──

describe('fmtNumber', () => {
  it('returns -- for undefined', () => {
    expect(fmtNumber(undefined)).toBe('--')
  })

  it('returns -- for null', () => {
    expect(fmtNumber(null)).toBe('--')
  })

  it('returns -- for NaN', () => {
    expect(fmtNumber(NaN)).toBe('--')
  })

  it('formats integer with ko-KR', () => {
    const result = fmtNumber(1234)
    expect(result).toContain('1,234')
  })

  it('formats with custom digits', () => {
    const result = fmtNumber(1234.567, 2)
    expect(result).toContain('1,234.57')
  })
})

// ── filterProviders ──

describe('filterProviders', () => {
  const providers: DashboardRuntimeProviderSnapshot[] = [
    makeProvider({
      provider: 'Ollama',
      runtime_kind: 'local',
      auth_kind: 'none',
      status: 'available',
      source: 'autodiscover',
      default_model: 'qwen3-30b',
      endpoint_url: 'http://127.0.0.1:11434',
      note: 'primary local runtime',
      models: ['qwen3-30b', 'llama3-8b'],
    }),
    makeProvider({
      provider: 'Anthropic',
      runtime_kind: 'cloud',
      auth_kind: 'api_key',
      status: 'available',
      source: 'config',
      default_model: 'claude-opus-4-7',
      endpoint_url: 'https://api.anthropic.com',
      models: ['claude-opus-4-7', 'claude-sonnet-4-7'],
    }),
    makeProvider({
      provider: 'GLM',
      runtime_kind: 'cloud',
      models: [],
    }),
  ]

  it('returns input reference when query is empty', () => {
    expect(filterProviders(providers, '')).toBe(providers)
  })

  it('returns input reference when query is whitespace', () => {
    expect(filterProviders(providers, '   ')).toBe(providers)
  })

  it('matches provider name case-insensitively', () => {
    const out = filterProviders(providers, 'ollama')
    expect(out.map(p => p.provider)).toEqual(['Ollama'])
  })

  it('trims query', () => {
    const out = filterProviders(providers, '  anthropic  ')
    expect(out.map(p => p.provider)).toEqual(['Anthropic'])
  })

  it('matches across multiple fields (runtime_kind, default_model, endpoint, catalog model, note)', () => {
    expect(filterProviders(providers, 'local').map(p => p.provider)).toEqual(['Ollama'])
    expect(filterProviders(providers, 'claude-opus').map(p => p.provider)).toEqual(['Anthropic'])
    expect(filterProviders(providers, '127.0.0.1').map(p => p.provider)).toEqual(['Ollama'])
    expect(filterProviders(providers, 'llama3-8b').map(p => p.provider)).toEqual(['Ollama'])
    expect(filterProviders(providers, 'primary local').map(p => p.provider)).toEqual(['Ollama'])
    expect(filterProviders(providers, 'cloud').map(p => p.provider)).toEqual(['Anthropic', 'GLM'])
  })

  it('returns empty when nothing matches', () => {
    expect(filterProviders(providers, 'nomatch-xyz')).toEqual([])
  })

  it('does not mutate the input', () => {
    const snapshot = providers.map(p => ({ ...p, models: [...p.models] }))
    filterProviders(providers, 'cloud')
    expect(providers).toEqual(snapshot)
  })
})

// ── filterModels ──

describe('filterModels', () => {
  const models: DashboardRuntimeModelMetric[] = [
    makeMetric({
      model_id: 'qwen3-30b-thinking',
      top_tools: [
        { tool: 'Read', count: 12 },
        { tool: 'Bash', count: 3 },
      ],
    }),
    makeMetric({
      model_id: 'claude-opus-4-7',
      top_tools: [
        { tool: 'Grep', count: 20 },
        { tool: 'Edit', count: 8 },
      ],
    }),
    makeMetric({
      model_id: 'glm-4-6',
      top_tools: null,
    }),
  ]

  it('returns input reference when query is empty', () => {
    expect(filterModels(models, '')).toBe(models)
  })

  it('returns input reference when query is whitespace', () => {
    expect(filterModels(models, '\t  \n')).toBe(models)
  })

  it('matches model_id case-insensitively', () => {
    const out = filterModels(models, 'QWEN3')
    expect(out.map(m => m.model_id)).toEqual(['qwen3-30b-thinking'])
  })

  it('trims query', () => {
    const out = filterModels(models, '  glm-4-6  ')
    expect(out.map(m => m.model_id)).toEqual(['glm-4-6'])
  })

  it('matches on top_tools name', () => {
    expect(filterModels(models, 'bash').map(m => m.model_id)).toEqual(['qwen3-30b-thinking'])
    expect(filterModels(models, 'grep').map(m => m.model_id)).toEqual(['claude-opus-4-7'])
  })

  it('returns empty when nothing matches', () => {
    expect(filterModels(models, 'nomatch-xyz')).toEqual([])
  })

  it('does not mutate the input', () => {
    const snapshot = models.map(m => ({ ...m, top_tools: m.top_tools ? [...m.top_tools] : m.top_tools }))
    filterModels(models, 'edit')
    expect(models).toEqual(snapshot)
  })
})
