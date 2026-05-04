import { describe, expect, it } from 'vitest'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { html } from 'htm/preact'
import { runtimeProviderToMatrixId, ANTI_PATTERNS } from './provider-capability-matrix/data'
import { FeatureMatrix, liveStatusDot } from './provider-capability-matrix/feature-matrix'
import { WiringGaps } from './provider-capability-matrix/wiring-gaps'
import { AntiPatternList } from './provider-capability-matrix/anti-patterns'
import type { DashboardRuntimeProviderSnapshot } from '../api/dashboard'

function container(): HTMLElement {
  return document.createElement('div')
}

describe('ProviderCapabilityMatrix', () => {
  it('maps live provider identity before runtime kind', () => {
    expect(runtimeProviderToMatrixId('codex-api', 'Codex_cli')).toBe('openai')
    expect(runtimeProviderToMatrixId('codex', 'OpenAI_compat')).toBe('codex_cli')
    expect(runtimeProviderToMatrixId('gemini', 'Gemini')).toBe('gemini_cli')
    expect(runtimeProviderToMatrixId('gemini-api', 'Gemini_cli')).toBe('gemini')
    expect(runtimeProviderToMatrixId('glm-api', 'GLM')).toBe('glm')
    expect(runtimeProviderToMatrixId('llama', null)).toBe('llamacpp')
  })

  it('derives live header status from availability and status vocabulary', () => {
    const providers: DashboardRuntimeProviderSnapshot[] = [
      { provider: 'codex-api', kind: 'Codex_cli', runtime_kind: 'OpenAI_compat', status: 'ok', available: true, models: [] },
      { provider: 'gemini', kind: 'Gemini_cli', runtime_kind: 'Gemini_cli', status: 'missing_auth', available: false, models: [] },
      { provider: 'glm-api', kind: 'GLM', runtime_kind: 'GLM', status: 'vertex_adc', available: true, models: [] },
    ]

    expect(liveStatusDot('openai', providers)).toBe('ok')
    expect(liveStatusDot('codex_cli', providers)).toBeNull()
    expect(liveStatusDot('gemini_cli', providers)).toBe('bad')
    expect(liveStatusDot('glm', providers)).toBe('warn')
  })

  it('smoke renders feature matrix with shared status dots', () => {
    const el = container()
    const providers: DashboardRuntimeProviderSnapshot[] = [
      { provider: 'codex-api', kind: 'Codex_cli', runtime_kind: 'OpenAI_compat', status: 'ok', available: true, models: [] },
      { provider: 'gemini', kind: 'Gemini_cli', runtime_kind: 'Gemini_cli', status: 'error', available: false, models: [] },
    ]

    render(html`<${FeatureMatrix} liveProviders=${providers} />`, el)

    expect(el.textContent).toContain('Native Tool Calling')
    expect(el.textContent).toContain('OpenAI')
    expect(el.querySelectorAll('[data-status-dot]').length).toBe(2)
  })

  it('renders only actionable wiring gaps while preserving summary counts', () => {
    const el = container()
    render(html`<${WiringGaps} />`, el)

    expect(el.textContent).toContain('HIGH')
    expect(el.textContent).toContain('MEDIUM')
    expect(el.textContent).toContain('LOW')
    expect(el.textContent).toContain('정확')
    expect(el.textContent).toContain('W01')
    expect(el.textContent).not.toContain('W07')
  })

  it('filters anti-pattern rows by category', async () => {
    const el = container()
    render(html`<${AntiPatternList} />`, el)

    const stringMatch = Array.from(el.querySelectorAll('button')).find(btn =>
      btn.textContent?.includes('String Match'),
    )
    expect(stringMatch).toBeDefined()

    await act(async () => {
      stringMatch!.click()
    })

    expect(el.textContent).toContain('M01')
    expect(el.textContent).not.toContain('S01')
  })

  it('all anti-patterns have source attribution with precise OAS locations', () => {
    for (const ap of ANTI_PATTERNS) {
      expect(ap.source).toBeDefined()
      expect(ap.location).toMatch(/\.\w+(:[\d,-]+)?$/)
    }
    const oasCount = ANTI_PATTERNS.filter(ap => ap.source === 'oas').length
    expect(oasCount).toBe(32)
  })
})
