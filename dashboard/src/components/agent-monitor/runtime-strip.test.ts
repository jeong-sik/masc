// @vitest-environment happy-dom
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, h } from 'preact'
import { AgentRuntimeStrip } from './runtime-strip'

const mockFindKeeper = vi.hoisted(() => vi.fn())
const mockKeeperDisplayModel = vi.hoisted(() => vi.fn())
const mockKeeperActivityDisplay = vi.hoisted(() => vi.fn())
const mockFormatDuration = vi.hoisted(() => vi.fn((s: number) => `${s}s`))

vi.mock('../../lib/keeper-utils', () => ({
  findKeeper: (...args: any[]) => mockFindKeeper(...args),
}))

vi.mock('../../lib/keeper-runtime-display', () => ({
  keeperDisplayModel: (...args: any[]) => mockKeeperDisplayModel(...args),
  keeperActivityDisplay: (...args: any[]) => mockKeeperActivityDisplay(...args),
}))

vi.mock('../mission-utils', () => ({
  formatDuration: (...args: any[]) => mockFormatDuration(...args),
}))

vi.mock('../keeper-pipeline-stage', () => ({
  PipelineStageBadge: ({ stage }: { stage?: string | null }) =>
    h('span', { className: 'pipeline-badge' }, stage ?? '-'),
}))

describe('AgentRuntimeStrip', () => {
  beforeEach(() => {
    mockFindKeeper.mockReset()
    mockKeeperDisplayModel.mockReset()
    mockKeeperActivityDisplay.mockReset()
    mockFormatDuration.mockReset()
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
      pipeline_stage: 'thinking',
      context_ratio: null,
      generation: null,
    })
    mockKeeperDisplayModel.mockReturnValue(null)
    mockKeeperActivityDisplay.mockReturnValue({ ageSeconds: null, label: '' })
    const container = document.createElement('div')
    render(h(AgentRuntimeStrip, { name: 'Alpha' }), container)
    expect(container.textContent).toContain('thinking')
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
