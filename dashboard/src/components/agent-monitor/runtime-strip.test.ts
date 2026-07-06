// @ts-nocheck
// @vitest-environment happy-dom
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, h } from 'preact'
import { AgentRuntimeStrip } from './runtime-strip'

const mockFindKeeper = vi.hoisted(() => vi.fn())
const mockKeeperDisplayModel = vi.hoisted(() => vi.fn())
const mockKeeperDisplayRuntime = vi.hoisted(() => vi.fn())
const mockKeeperActivityDisplay = vi.hoisted(() => vi.fn())
const mockFormatDuration = vi.hoisted(() => vi.fn((s: number) => `${s}s`))
const mockFindRuntimeCatalogEntry = vi.hoisted(() => vi.fn())
const mockLoadRuntimeCatalog = vi.hoisted(() => vi.fn())
const mockRuntimeCatalogState = vi.hoisted(() => ({ value: { status: 'idle' } }))
const mockRuntimeCatalogSnapshotFacts = vi.hoisted(() => vi.fn())
const mockRuntimeCatalogEffectiveCapabilities = vi.hoisted(() => vi.fn())

vi.mock('../../lib/keeper-utils', () => ({
  findKeeper: (...args: Parameters<typeof mockFindKeeper>) => mockFindKeeper(...args),
}))

vi.mock('../../lib/keeper-runtime-display', () => ({
  keeperDisplayModel: (...args: Parameters<typeof mockKeeperDisplayModel>) => mockKeeperDisplayModel(...args),
  keeperDisplayRuntime: (...args: Parameters<typeof mockKeeperDisplayRuntime>) => mockKeeperDisplayRuntime(...args),
  keeperActivityDisplay: (...args: Parameters<typeof mockKeeperActivityDisplay>) => mockKeeperActivityDisplay(...args),
}))

vi.mock('../../lib/runtime-catalog-resource', () => ({
  findRuntimeCatalogEntry: (...args: Parameters<typeof mockFindRuntimeCatalogEntry>) =>
    mockFindRuntimeCatalogEntry(...args),
  loadRuntimeCatalog: mockLoadRuntimeCatalog,
  runtimeCatalogState: mockRuntimeCatalogState,
}))

vi.mock('../../lib/runtime-provider-summary', () => ({
  runtimeCatalogEffectiveCapabilities: (...args: Parameters<typeof mockRuntimeCatalogEffectiveCapabilities>) =>
    mockRuntimeCatalogEffectiveCapabilities(...args),
  runtimeCatalogSnapshotFacts: (...args: Parameters<typeof mockRuntimeCatalogSnapshotFacts>) =>
    mockRuntimeCatalogSnapshotFacts(...args),
}))

vi.mock('../../lib/format-time', () => ({
  formatDuration: (...args: Parameters<typeof mockFormatDuration>) => mockFormatDuration(...args),
}))

vi.mock('../keeper-pipeline-stage', () => ({
  PipelineStageBadge: ({ stage }: { stage?: string | null }) =>
    h('span', { className: 'pipeline-badge' }, stage ?? '-'),
}))

describe('AgentRuntimeStrip', () => {
  beforeEach(() => {
    mockFindKeeper.mockReset()
    mockKeeperDisplayModel.mockReset()
    mockKeeperDisplayRuntime.mockReset()
    mockKeeperActivityDisplay.mockReset()
    mockFormatDuration.mockReset()
    mockFindRuntimeCatalogEntry.mockReset()
    mockLoadRuntimeCatalog.mockReset()
    mockRuntimeCatalogSnapshotFacts.mockReset()
    mockRuntimeCatalogEffectiveCapabilities.mockReset()
    mockKeeperDisplayRuntime.mockReturnValue(null)
    mockRuntimeCatalogState.value = { status: 'idle' }
    mockFormatDuration.mockImplementation((s: number) => `${s}s`)
  })

  it('returns empty when keeper not found', () => {
    mockFindKeeper.mockReturnValue(null)
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    expect(container.textContent).toBe('')
  })

  it('renders pipeline stage badge', () => {
    mockFindKeeper.mockReturnValue({
      pipeline_stage: 'compacting',
      context_ratio: null,
      generation: null,
    })
    mockKeeperDisplayModel.mockReturnValue(null)
    mockKeeperActivityDisplay.mockReturnValue({ ageSeconds: null, label: '' })
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    // STAGES short label for `compacting` is `compact`.
    expect(container.textContent).toContain('compact')
    expect(container.querySelector('.v2-monitoring-detail')).not.toBeNull()
  })

  it('renders context ratio bar when present', () => {
    mockFindKeeper.mockReturnValue({
      pipeline_stage: null,
      context_ratio: 0.65,
      generation: null,
    })
    mockKeeperDisplayModel.mockReturnValue(null)
    mockKeeperActivityDisplay.mockReturnValue({ ageSeconds: null, label: '' })
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    expect(container.textContent).toContain('CTX')
    expect(container.textContent).toContain('65%')
    const fill = container.querySelector('.agent-runtime-ctx-fill')
    expect(fill).not.toBeNull()
    expect(fill!.classList.contains('warn')).toBe(true)
  })

  it('renders generation when present', () => {
    mockFindKeeper.mockReturnValue({
      pipeline_stage: null,
      context_ratio: null,
      generation: 42,
    })
    mockKeeperDisplayModel.mockReturnValue(null)
    mockKeeperActivityDisplay.mockReturnValue({ ageSeconds: null, label: '' })
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    expect(container.textContent).toContain('GEN')
    expect(container.textContent).toContain('42')
  })

  it('renders model info when present', () => {
    mockFindKeeper.mockReturnValue({
      pipeline_stage: null,
      context_ratio: null,
      generation: null,
    })
    mockKeeperDisplayModel.mockReturnValue({ label: 'Model', value: 'claude-4' })
    mockKeeperActivityDisplay.mockReturnValue({ ageSeconds: null, label: '' })
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    expect(container.textContent).toContain('Model')
    expect(container.textContent).toContain('claude-4')
  })

  it('does not load runtime catalog when no runtime evidence exists', () => {
    mockFindKeeper.mockReturnValue({
      pipeline_stage: null,
      context_ratio: null,
      generation: null,
    })
    mockKeeperDisplayModel.mockReturnValue(null)
    mockKeeperDisplayRuntime.mockReturnValue(null)
    mockKeeperActivityDisplay.mockReturnValue({ ageSeconds: null, label: '' })
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    expect(mockLoadRuntimeCatalog).not.toHaveBeenCalled()
    expect(mockFindRuntimeCatalogEntry).not.toHaveBeenCalled()
    expect(mockRuntimeCatalogSnapshotFacts).not.toHaveBeenCalled()
    expect(mockRuntimeCatalogEffectiveCapabilities).not.toHaveBeenCalled()
  })

  it('renders runtime lane when present', () => {
    mockFindKeeper.mockReturnValue({
      pipeline_stage: null,
      context_ratio: null,
      generation: null,
    })
    mockKeeperDisplayModel.mockReturnValue(null)
    mockKeeperDisplayRuntime.mockReturnValue({ label: 'Runtime', value: 'oas.primary' })
    mockKeeperActivityDisplay.mockReturnValue({ ageSeconds: null, label: '' })
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    expect(mockLoadRuntimeCatalog).toHaveBeenCalled()
    expect(container.textContent).toContain('Runtime')
    expect(container.textContent).toContain('oas.primary')
  })

  it('renders runtime catalog facts when a catalog entry is loaded', () => {
    const entry = { runtime_id: 'oas.primary' }
    mockFindKeeper.mockReturnValue({
      pipeline_stage: null,
      context_ratio: null,
      generation: null,
    })
    mockRuntimeCatalogState.value = { status: 'loaded', data: [entry] }
    mockKeeperDisplayModel.mockReturnValue(null)
    mockKeeperDisplayRuntime.mockReturnValue({ label: 'Runtime', value: 'oas.primary' })
    mockKeeperActivityDisplay.mockReturnValue({ ageSeconds: null, label: '' })
    mockFindRuntimeCatalogEntry.mockReturnValue(entry)
    mockRuntimeCatalogSnapshotFacts.mockReturnValue('caps:declared · format:json,schema')
    mockRuntimeCatalogEffectiveCapabilities.mockReturnValue(
      'source:oas-provider-config-model · input:multimodal,image · wire:chat-template-kwargs',
    )
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    expect(mockFindRuntimeCatalogEntry).toHaveBeenCalledWith([entry], 'oas.primary')
    expect(mockRuntimeCatalogSnapshotFacts).toHaveBeenCalledWith(entry)
    expect(mockRuntimeCatalogEffectiveCapabilities).toHaveBeenCalledWith(entry)
    expect(container.textContent).toContain('SPEC')
    expect(container.textContent).toContain('caps:declared · format:json,schema')
    expect(container.textContent).toContain('source:oas-provider-config-model')
    expect(container.textContent).toContain('input:multimodal,image')
    expect(container.textContent).toContain('wire:chat-template-kwargs')
  })

  it('renders explicit spec status when the catalog load failed', () => {
    mockFindKeeper.mockReturnValue({
      pipeline_stage: null,
      context_ratio: null,
      generation: null,
    })
    mockRuntimeCatalogState.value = { status: 'error', message: 'fetch failed' }
    mockKeeperDisplayModel.mockReturnValue(null)
    mockKeeperDisplayRuntime.mockReturnValue({ label: 'Runtime', value: 'oas.primary' })
    mockKeeperActivityDisplay.mockReturnValue({ ageSeconds: null, label: '' })
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    expect(container.textContent).toContain('SPEC')
    expect(container.textContent).toContain('catalog unavailable')
    expect(container.querySelector('[title="fetch failed"]')).not.toBeNull()
  })

  it('renders explicit spec status when the runtime is absent from the loaded catalog', () => {
    mockFindKeeper.mockReturnValue({
      pipeline_stage: null,
      context_ratio: null,
      generation: null,
    })
    mockRuntimeCatalogState.value = { status: 'loaded', data: [] }
    mockKeeperDisplayModel.mockReturnValue(null)
    mockKeeperDisplayRuntime.mockReturnValue({ label: 'Runtime', value: 'oas.primary' })
    mockKeeperActivityDisplay.mockReturnValue({ ageSeconds: null, label: '' })
    mockFindRuntimeCatalogEntry.mockReturnValue(null)
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    expect(container.textContent).toContain('SPEC')
    expect(container.textContent).toContain('catalog entry missing')
  })

  it('renders activity when ageSeconds present', () => {
    mockFindKeeper.mockReturnValue({
      pipeline_stage: null,
      context_ratio: null,
      generation: null,
    })
    mockKeeperDisplayModel.mockReturnValue(null)
    mockKeeperActivityDisplay.mockReturnValue({ ageSeconds: 120, label: 'idle' })
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    expect(container.textContent).toContain('ACTIVITY')
    expect(container.textContent).toContain('idle')
    expect(container.textContent).toContain('120s')
  })

  it('applies bad class for high context ratio', () => {
    mockFindKeeper.mockReturnValue({
      pipeline_stage: null,
      context_ratio: 0.85,
      generation: null,
    })
    mockKeeperDisplayModel.mockReturnValue(null)
    mockKeeperActivityDisplay.mockReturnValue({ ageSeconds: null, label: '' })
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    const fill = container.querySelector('.agent-runtime-ctx-fill')
    expect(fill!.classList.contains('bad')).toBe(true)
  })

  it('applies no extra class for low context ratio', () => {
    mockFindKeeper.mockReturnValue({
      pipeline_stage: null,
      context_ratio: 0.3,
      generation: null,
    })
    mockKeeperDisplayModel.mockReturnValue(null)
    mockKeeperActivityDisplay.mockReturnValue({ ageSeconds: null, label: '' })
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    const fill = container.querySelector('.agent-runtime-ctx-fill') as HTMLElement
    expect(fill!.classList.contains('warn')).toBe(false)
    expect(fill!.classList.contains('bad')).toBe(false)
  })

  it('infers idle stage from last_turn_ago_s under threshold', () => {
    mockFindKeeper.mockReturnValue({
      pipeline_stage: null,
      last_turn_ago_s: 30,
      context_ratio: null,
      generation: null,
    })
    mockKeeperDisplayModel.mockReturnValue(null)
    mockKeeperActivityDisplay.mockReturnValue({ ageSeconds: null, label: '' })
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    expect(container.textContent).toContain('idle')
  })

  it('does not infer idle stage when last_turn_ago_s exceeds threshold', () => {
    mockFindKeeper.mockReturnValue({
      pipeline_stage: null,
      last_turn_ago_s: 900,
      context_ratio: null,
      generation: null,
    })
    mockKeeperDisplayModel.mockReturnValue(null)
    mockKeeperActivityDisplay.mockReturnValue({ ageSeconds: null, label: '' })
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    expect(container.textContent).not.toContain('idle')
  })
})
