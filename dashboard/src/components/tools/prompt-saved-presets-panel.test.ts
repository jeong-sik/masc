import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { Signal } from '@preact/signals'
import type { ExecutionWorkspaceAuthority } from '../../store'

const mocks = vi.hoisted(() => ({
  fetchPromptPresets: vi.fn(), fetchPromptPresetDetail: vi.fn(), savePromptPreset: vi.fn(), restorePromptPreset: vi.fn(),
}))
const workspace = vi.hoisted(() => ({ current: null as unknown as Signal<ExecutionWorkspaceAuthority | null> }))
vi.mock('../../store', async () => {
  const { signal } = await import('@preact/signals')
  workspace.current = signal<ExecutionWorkspaceAuthority | null>(null)
  return { executionWorkspaceAuthority: workspace.current, refreshExecution: vi.fn() }
})
vi.mock('../../api/prompt-presets', async importOriginal => ({
  ...await importOriginal<typeof import('../../api/prompt-presets')>(), ...mocks,
}))
import { PromptSavedPresetsPanel } from './prompt-saved-presets-panel'
import { resetPromptPresetSessionsForTesting } from '../../lib/prompt-preset-session'

const manifest = (name = 'morning') => ({
  schema_version: 1, name, description: 'saved', created_at: '2026-10-07T02:15:46Z',
  override_count: 0, override_keys: [], keepers: ['keeper'], assignment_count: 1, lane_count: 1,
})
const defaults = { status: 'unknown', changes: [] }
const detail = (name = 'morning') => ({
  ok: true, directory: `/fixture/presets/${name}`, saved_settings: { status: 'differs' }, default_prompts: defaults,
  preset: { name, description: 'saved', created_at: '2026-10-07T02:15:46Z', prompt_overrides: [], instructions: [], assignments: [], lanes: [],
    preserved_lane_settings: [{ lane: 'verifier_exact', setting: 'thinking' }] },
})
const part = { effect: 'immediate', applied: [], skipped: [] }
const report = { restored: 'morning', autosave: '_autosave', prompt_overrides: part,
  instructions: { ...part, skipped: [{ key: 'missing-keeper', reason: 'not configured' }] },
  runtime: { effect: 'runtime_commit', status: 'unchanged' }, default_prompts: defaults,
  preserved_lane_settings: [{ lane: 'verifier_exact', setting: 'thinking' }],
}

let container: HTMLDivElement
const button = (id: string) => container.querySelector<HTMLButtonElement>(`[data-testid="${id}"]`)!
const input = (id: string) => container.querySelector<HTMLInputElement>(`[data-testid="${id}"]`)!
const ready = () => waitFor(() => expect(button('prompt-presets-restore').disabled).toBe(false))

describe('saved prompt preset actions', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    resetPromptPresetSessionsForTesting()
    workspace.current.value = { epoch: 'fixture', workspaceRoot: '/workspace-a', connectionGeneration: 1 }
    mocks.fetchPromptPresets.mockResolvedValue({ ok: true, presets: [manifest()], unreadable: [] })
    mocks.fetchPromptPresetDetail.mockImplementation(async (name: string) => detail(name))
    mocks.restorePromptPreset.mockResolvedValue({ kind: 'confirmed', value: report })
    mocks.savePromptPreset.mockImplementation(async (name: string) => ({ kind: 'confirmed', value: manifest(name) }))
    container = document.createElement('div')
    document.body.append(container)
  })
  afterEach(() => { render(null, container); container.remove() })

  it('requires a confirmation, sends once, retains partial effects, and rereads after restore', async () => {
    const onRestored = vi.fn()
    render(html`<${PromptSavedPresetsPanel} onRestored=${onRestored} />`, container)
    await ready()
    expect(container.querySelector('[data-preset-preserved-settings]')).not.toBeNull()
    fireEvent.click(button('prompt-presets-restore'))
    await waitFor(() => expect(button('prompt-presets-confirm')).not.toBeNull())
    expect(mocks.restorePromptPreset).not.toHaveBeenCalled()
    const confirm = button('prompt-presets-confirm')
    fireEvent.click(confirm)
    fireEvent.click(confirm)
    await waitFor(() => expect(container.querySelector('[data-preset-report]')?.getAttribute('data-needs-attention')).toBe('true'))
    expect(mocks.restorePromptPreset).toHaveBeenCalledExactlyOnceWith('morning', expect.objectContaining({ beforeDispatch: expect.any(Function) }))
    expect(onRestored).toHaveBeenCalledOnce()
    expect(mocks.fetchPromptPresets).toHaveBeenCalledTimes(2)
    await waitFor(() => expect(mocks.fetchPromptPresetDetail).toHaveBeenCalledTimes(2))
  })

  it('does not overwrite existing or unreadable names and sends a new name with its description', async () => {
    mocks.fetchPromptPresets.mockResolvedValue({ ok: true, presets: [manifest()], unreadable: [{ name: 'broken', reason: 'invalid file' }] })
    render(html`<${PromptSavedPresetsPanel} />`, container)
    await ready()
    for (const name of ['morning', 'broken']) {
      fireEvent.input(input('prompt-presets-name'), { target: { value: name } })
      await waitFor(() => expect(button('prompt-presets-save').disabled).toBe(true))
      fireEvent.submit(container.querySelector('form')!)
      expect(mocks.savePromptPreset).not.toHaveBeenCalled()
    }
    fireEvent.input(input('prompt-presets-name'), { target: { value: 'new' } })
    fireEvent.input(container.querySelector('[aria-label="저장본 설명"]')!, { target: { value: 'before experiment' } })
    await waitFor(() => expect(button('prompt-presets-save').disabled).toBe(false))
    fireEvent.submit(container.querySelector('form')!)
    await waitFor(() => expect(mocks.savePromptPreset).toHaveBeenCalledExactlyOnceWith('new', 'before experiment', expect.objectContaining({ beforeDispatch: expect.any(Function) })))
  })

  it('does not replay an unconfirmed restore and requires a fresh read before a new action', async () => {
    mocks.restorePromptPreset.mockResolvedValue({ kind: 'unconfirmed', detail: 'connection closed' })
    render(html`<${PromptSavedPresetsPanel} />`, container)
    await ready()
    fireEvent.click(button('prompt-presets-restore'))
    await waitFor(() => expect(button('prompt-presets-confirm')).not.toBeNull())
    fireEvent.click(button('prompt-presets-confirm'))
    await waitFor(() => expect(container.querySelector('[data-preset-write-unconfirmed]')).not.toBeNull())
    expect(mocks.restorePromptPreset).toHaveBeenCalledOnce()
    expect(mocks.fetchPromptPresets).toHaveBeenCalledOnce()
    expect(button('prompt-presets-restore').disabled).toBe(true)
    fireEvent.click(button('prompt-presets-refresh'))
    await ready()
    expect(mocks.fetchPromptPresets).toHaveBeenCalledTimes(2)
    expect(mocks.restorePromptPreset).toHaveBeenCalledOnce()
    expect(container.querySelector('[data-preset-write-unconfirmed]')).not.toBeNull()
  })

  it('does not apply a late detail response to a different selection', async () => {
    mocks.fetchPromptPresets.mockResolvedValue({ ok: true, presets: [manifest('morning'), manifest('evening')], unreadable: [] })
    let finishMorning!: (value: ReturnType<typeof detail>) => void
    mocks.fetchPromptPresetDetail.mockImplementation((name: string) => name === 'morning'
      ? new Promise(resolve => { finishMorning = resolve }) : Promise.resolve(detail(name)))
    render(html`<${PromptSavedPresetsPanel} />`, container)
    await waitFor(() => expect(mocks.fetchPromptPresetDetail).toHaveBeenCalledWith('morning'))
    fireEvent.change(container.querySelector('select')!, { target: { value: 'evening' } })
    await ready()
    finishMorning(detail('morning'))
    await waitFor(() => expect(container.querySelector('[data-preset-detail]')?.getAttribute('data-preset-detail')).toBe('evening'))
    fireEvent.click(button('prompt-presets-restore'))
    await waitFor(() => expect(button('prompt-presets-confirm')).not.toBeNull())
    fireEvent.click(button('prompt-presets-confirm'))
    await waitFor(() => expect(mocks.restorePromptPreset).toHaveBeenCalledExactlyOnceWith('evening', expect.objectContaining({ beforeDispatch: expect.any(Function) })))
  })

  it('withdraws confirmation and ignores an old read when the workspace authority changes', async () => {
    let finishOld!: (value: ReturnType<typeof detail>) => void
    mocks.fetchPromptPresetDetail.mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve }))
    render(html`<${PromptSavedPresetsPanel} />`, container)
    await waitFor(() => expect(mocks.fetchPromptPresetDetail).toHaveBeenCalledWith('morning'))
    workspace.current.value = null
    await waitFor(() => expect(container.querySelector('[data-testid="prompt-presets-restore"]')).toBeNull())
    mocks.fetchPromptPresets.mockResolvedValue({ ok: true, presets: [manifest('evening')], unreadable: [] })
    workspace.current.value = { epoch: 'fixture', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    await ready()
    finishOld(detail('morning'))
    await waitFor(() => expect(container.querySelector('[data-preset-detail]')?.getAttribute('data-preset-detail')).toBe('evening'))
    fireEvent.click(button('prompt-presets-restore'))
    await waitFor(() => expect(button('prompt-presets-confirm')).not.toBeNull())
    workspace.current.value = { epoch: 'fixture', workspaceRoot: '/workspace-a', connectionGeneration: 3 }
    await waitFor(() => expect(container.querySelector('[data-preset-confirmation]')).toBeNull())
    expect(mocks.restorePromptPreset).not.toHaveBeenCalled()
  })

  it('retains a sent operation and its uncertain result across unmount and remount', async () => {
    let finish!: (value: { kind: 'unconfirmed'; detail: string }) => void
    mocks.restorePromptPreset.mockImplementation(() => new Promise(resolve => { finish = resolve }))
    render(html`<${PromptSavedPresetsPanel} />`, container)
    await ready()
    fireEvent.click(button('prompt-presets-restore'))
    await waitFor(() => expect(button('prompt-presets-confirm')).not.toBeNull())
    fireEvent.click(button('prompt-presets-confirm'))
    await waitFor(() => expect(mocks.restorePromptPreset).toHaveBeenCalledOnce())
    render(null, container)
    render(html`<${PromptSavedPresetsPanel} />`, container)
    await waitFor(() => expect(container.querySelector('[data-preset-detail]')).not.toBeNull())
    expect(button('prompt-presets-restore').disabled).toBe(true)
    render(null, container)
    finish({ kind: 'unconfirmed', detail: 'connection closed' })
    await Promise.resolve()
    render(html`<${PromptSavedPresetsPanel} />`, container)
    await waitFor(() => expect(container.querySelector('[data-preset-write-unconfirmed]')).not.toBeNull())
    await waitFor(() => expect(container.querySelector('[data-preset-detail]')).not.toBeNull())
    expect(button('prompt-presets-restore').disabled).toBe(true)
    expect(mocks.restorePromptPreset).toHaveBeenCalledOnce()
    fireEvent.click(button('prompt-presets-refresh'))
    await ready()
    expect(mocks.restorePromptPreset).toHaveBeenCalledOnce()
  })
})
