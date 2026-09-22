import { h, render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { FusionConfigSnapshot, FusionPresetConfigView, RuntimeResolvedResponse } from '../api/dashboard'
import { committedRuntimeTomlConfigFixture } from '../lib/runtime-config-receipt.test-fixture'

const fusionConfigMock = vi.fn<() => Promise<FusionConfigSnapshot>>()
const resolvedMock = vi.fn<() => Promise<RuntimeResolvedResponse>>()
const applyMock = vi.fn<(revision: string, operation: unknown) => Promise<unknown>>()
const runtimeRefreshMock = vi.fn(async () => undefined)

vi.mock('../api/dashboard', async () => {
  // The panel decides "conflict or not" with instanceof, so the class it sees
  // must be the one the test throws: the real one, through the mock.
  const fusion = await vi.importActual<typeof import('../api/dashboard-fusion')>('../api/dashboard-fusion')
  return {
    fetchFusionConfig: () => fusionConfigMock(),
    fetchRuntimeResolved: () => resolvedMock(),
    applyFusionConfigEdit: (revision: string, operation: unknown) => applyMock(revision, operation),
    FusionConfigEditError: fusion.FusionConfigEditError,
    runnableTopologies: fusion.runnableTopologies,
  }
})
vi.mock('../lib/runtime-config-refresh', () => ({
  refreshRuntimeConfigConsumers: () => runtimeRefreshMock(),
}))

const { FusionConfigEditError } = await import('../api/dashboard')

function preset(name: string, over: Partial<FusionPresetConfigView> = {}): FusionPresetConfigView {
  return {
    name,
    panels: [
      {
        models: ['p.one', 'p.two'],
        label: '',
        systemPrompt: 'panelist',
        webTools: false,
        maxOutputTokens: null,
        timeoutS: 240,
      },
    ],
    judge: 'meta.judge',
    judgeSystemPrompt: 'judge',
    judgeMaxOutputTokens: null,
    judgeTimeoutS: null,
    judges: [],
    minAnswered: 2,
    ...over,
  }
}

function snapshot(over: Partial<FusionConfigSnapshot> = {}): FusionConfigSnapshot {
  return {
    enabled: true,
    defaultPreset: 'trio',
    stagedJudgeGroupSize: 3,
    presets: [preset('trio'), preset('duo', { minAnswered: 1 })],
    sourceRevision: 'rev-1',
    ...over,
  }
}

function runtime(id: string): RuntimeResolvedResponse['runtimes'][number] {
  return {
    id,
    provider: 'p',
    model: 'm',
    effective_max_context: 1,
    max_context_source: 'capability',
    max_output_tokens: null,
    is_local: false,
    is_default: false,
  }
}

const RESOLVED: RuntimeResolvedResponse = {
  config_path: null,
  default_runtime: null,
  runtimes: [runtime('p.one'), runtime('p.two'), runtime('p.three'), runtime('meta.judge')],
  lanes: [{ id: 'lane.fast', declared: true, runtime_ids: ['p.one', 'p.two'] }],
  assignments: [],
}

const receipt = () =>
  committedRuntimeTomlConfigFixture({
    ok: true,
    path: '/tmp/.masc/config/runtime.toml',
    file_name: 'runtime.toml',
    source_text: '[fusion]\nenabled = true\n',
  })

let container: HTMLDivElement
const q = (sel: string) => container.querySelector(sel)
const qa = (sel: string) => Array.from(container.querySelectorAll(sel))
const input = (sel: string) => q(sel) as HTMLInputElement
const select = (sel: string) => q(sel) as HTMLSelectElement
const button = (sel: string) => q(sel) as HTMLButtonElement
const realConfirm = window.confirm

function setConfirm(value: ((message?: string) => boolean) | undefined): void {
  Object.defineProperty(window, 'confirm', { value, configurable: true, writable: true })
}

async function typeInto(sel: string, value: string) {
  const field = input(sel)
  field.value = value
  await fireEvent.input(field)
}

async function choose(sel: string, value: string) {
  const field = select(sel)
  field.value = value
  await fireEvent.change(field)
}

beforeEach(() => {
  fusionConfigMock.mockReset()
  resolvedMock.mockReset()
  applyMock.mockReset()
  runtimeRefreshMock.mockClear()
  fusionConfigMock.mockResolvedValue(snapshot())
  resolvedMock.mockResolvedValue(RESOLVED)
  applyMock.mockResolvedValue(receipt())
  container = document.createElement('div')
  document.body.appendChild(container)
})
afterEach(() => {
  render(null, container)
  container.remove()
  setConfirm(realConfirm)
})

async function mount() {
  const { FusionSettingsPanel } = await import('./fusion-settings-panel')
  render(h(FusionSettingsPanel, {}), container)
  await vi.waitFor(() => expect(q('[data-testid="fusion-settings-editor"]')).not.toBeNull())
}

async function savedNotice() {
  await vi.waitFor(() => expect(q('[data-testid="fusion-settings-saved"]')).not.toBeNull())
  return q('[data-testid="fusion-settings-saved"]')?.textContent ?? ''
}

describe('FusionSettingsPanel', () => {
  it('opens the default preset from the typed config with its routes and revision', async () => {
    await mount()
    expect(q('[data-testid="fusion-settings-revision"]')?.textContent).toBe('rev-1')
    expect(input('[data-testid="fusion-enabled"]').checked).toBe(true)
    expect(select('[data-testid="fusion-default-preset"]').value).toBe('trio')
    expect(qa('[data-testid="fusion-default-preset"] option').map(o => (o as HTMLOptionElement).value))
      .toEqual(['', 'trio', 'duo'])
    expect(input('[data-testid="fusion-staged-judge-group-size"]').value).toBe('3')
    expect(select('[data-testid="fusion-preset-select"]').value).toBe('trio')
    expect(input('[data-testid="fusion-preset-name"]').value).toBe('trio')
    expect(qa('[data-testid="fusion-panel-models-chip"]').map(chip => chip.textContent?.replace('×', '').trim()))
      .toEqual(['p.one', 'p.two'])
    expect(input('[data-testid="fusion-panel-timeout-s"]').value).toBe('240')
    expect(select('[data-testid="fusion-judge-route"]').value).toBe('meta.judge')
    expect(input('[data-testid="fusion-min-answered"]').value).toBe('2')
    // Routes come grouped: lanes first, then runtimes; picked models leave the add list.
    expect(qa('[data-testid="fusion-judge-route"] optgroup').map(g => (g as HTMLOptGroupElement).label))
      .toEqual(['lane', 'runtime'])
    expect(qa('[data-testid="fusion-panel-models-add"] option').map(o => (o as HTMLOptionElement).value))
      .toEqual(['', 'lane.fast', 'p.three', 'meta.judge'])
    // The saved composition card reads the same value.
    expect(q('[data-testid="fusion-preset-view"]')).not.toBeNull()
  })

  it('saves settings as set_settings against the loaded revision', async () => {
    await mount()
    await fireEvent.click(input('[data-testid="fusion-enabled"]'))
    await typeInto('[data-testid="fusion-staged-judge-group-size"]', '4')
    await choose('[data-testid="fusion-default-preset"]', 'duo')
    button('[data-testid="fusion-settings-save"]').click()

    await vi.waitFor(() => expect(applyMock).toHaveBeenCalledTimes(1))
    expect(applyMock.mock.calls[0]).toEqual(['rev-1', {
      kind: 'set_settings',
      enabled: false,
      defaultPreset: 'duo',
      stagedJudgeGroupSize: 4,
    }])
    const notice = await savedNotice()
    expect(notice).toContain('Skill catalog 게시됨')
    expect(fusionConfigMock).toHaveBeenCalledTimes(2)
    expect(runtimeRefreshMock).toHaveBeenCalledTimes(1)
  })

  it('saves the preset as upsert_preset and uses the refetched revision for the next save', async () => {
    fusionConfigMock
      .mockResolvedValueOnce(snapshot())
      .mockResolvedValueOnce(snapshot({ sourceRevision: 'rev-2' }))
      .mockResolvedValueOnce(snapshot({ sourceRevision: 'rev-3' }))
    await mount()
    await typeInto('[data-testid="fusion-panel-label"]', 'wide')
    await choose('[data-testid="fusion-panel-models-add"]', 'lane.fast')
    button('[data-testid="fusion-preset-save"]').click()

    await vi.waitFor(() => expect(applyMock).toHaveBeenCalledTimes(1))
    expect(applyMock.mock.calls[0]).toEqual(['rev-1', {
      kind: 'upsert_preset',
      preset: preset('trio', {
        panels: [
          {
            models: ['p.one', 'p.two', 'lane.fast'],
            label: 'wide',
            systemPrompt: 'panelist',
            webTools: false,
            maxOutputTokens: null,
            timeoutS: 240,
          },
        ],
      }),
    }])
    await savedNotice()
    expect(q('[data-testid="fusion-settings-revision"]')?.textContent).toBe('rev-2')

    button('[data-testid="fusion-preset-save"]').click()
    await vi.waitFor(() => expect(applyMock).toHaveBeenCalledTimes(2))
    expect(applyMock.mock.calls[1]?.[0]).toBe('rev-2')
  })

  it('replaces only the draft a write came from', async () => {
    await mount()
    // An unsaved settings edit must survive a preset write, and vice versa.
    await fireEvent.click(input('[data-testid="fusion-enabled"]'))
    await typeInto('[data-testid="fusion-panel-label"]', 'wide')
    button('[data-testid="fusion-preset-save"]').click()
    await savedNotice()
    expect(input('[data-testid="fusion-enabled"]').checked).toBe(false)
    // The preset draft now reflects the refetched config (label '' in the fixture).
    expect(input('[data-testid="fusion-panel-label"]').value).toBe('')

    await typeInto('[data-testid="fusion-panel-label"]', 'again')
    button('[data-testid="fusion-settings-save"]').click()
    await vi.waitFor(() => expect(applyMock).toHaveBeenCalledTimes(2))
    await savedNotice()
    expect(input('[data-testid="fusion-panel-label"]').value).toBe('again')
    expect(input('[data-testid="fusion-enabled"]').checked).toBe(true)
  })

  it('shows the server sentence on a conflict and reloads on request, discarding the draft', async () => {
    applyMock.mockRejectedValue(new FusionConfigEditError(
      {
        code: 'configuration_changed',
        message: 'runtime.toml changed after it was read; reload the settings and apply again',
      },
      409,
    ))
    fusionConfigMock
      .mockResolvedValueOnce(snapshot())
      .mockResolvedValueOnce(snapshot({ sourceRevision: 'rev-9' }))
    await mount()
    await typeInto('[data-testid="fusion-panel-label"]', 'wide')
    button('[data-testid="fusion-preset-save"]').click()

    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-error"]')).not.toBeNull())
    expect(q('[data-testid="fusion-settings-error"]')?.textContent)
      .toBe('runtime.toml changed after it was read; reload the settings and apply again')
    expect(q('[data-testid="fusion-settings-saved"]')).toBeNull()
    expect(runtimeRefreshMock).not.toHaveBeenCalled()

    button('[data-testid="fusion-settings-reload"]').click()
    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-revision"]')?.textContent).toBe('rev-9'))
    expect(fusionConfigMock).toHaveBeenCalledTimes(2)
    expect(resolvedMock).toHaveBeenCalledTimes(2)
    expect(input('[data-testid="fusion-panel-label"]').value).toBe('')
    expect(q('[data-testid="fusion-settings-error"]')).toBeNull()
  })

  it('shows other refusals verbatim without a reload button', async () => {
    applyMock.mockRejectedValue(new FusionConfigEditError(
      {
        code: 'route_unresolved',
        message: 'preset trio names ghost, which is not a loaded lane or runtime',
        preset: 'trio',
        route: 'ghost',
        reason: 'route_missing',
      },
      400,
    ))
    await mount()
    button('[data-testid="fusion-preset-save"]').click()

    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-error"]')).not.toBeNull())
    expect(q('[data-testid="fusion-settings-error"]')?.textContent)
      .toBe('preset trio names ghost, which is not a loaded lane or runtime')
    expect(q('[data-testid="fusion-settings-reload"]')).toBeNull()
  })

  it('shows a settings write the writer could not address verbatim', async () => {
    // set_settings answers edit_refused when [fusion] is written as dotted keys
    // or an inline table, which the line-surgical writer cannot edit. The
    // sentence names the table and says where to go instead, so it is shown as
    // it arrives; nothing about it is a conflict, so no reload is offered and
    // the config is not refetched.
    const refusal = 'fusion is not written as a [fusion] table with its keys right below the header; '
      + 'edit it in the raw runtime.toml'
    applyMock.mockRejectedValue(new FusionConfigEditError({ code: 'edit_refused', message: refusal }, 400))
    await mount()
    button('[data-testid="fusion-settings-save"]').click()

    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-error"]')).not.toBeNull())
    expect(q('[data-testid="fusion-settings-error"]')?.textContent).toBe(refusal)
    expect(q('[data-testid="fusion-settings-reload"]')).toBeNull()
    expect(q('[data-testid="fusion-settings-saved"]')).toBeNull()
    expect(fusionConfigMock).toHaveBeenCalledTimes(1)
    expect(runtimeRefreshMock).not.toHaveBeenCalled()
  })

  it('creates a new preset by copying the draft under the typed name', async () => {
    fusionConfigMock
      .mockResolvedValueOnce(snapshot())
      .mockResolvedValueOnce(snapshot({ presets: [preset('trio'), preset('duo'), preset('trio-copy')] }))
    await mount()
    await typeInto('[data-testid="fusion-preset-name"]', 'trio-copy')
    expect(button('[data-testid="fusion-preset-save"]').disabled).toBe(true)
    expect(button('[data-testid="fusion-preset-create"]').disabled).toBe(false)
    button('[data-testid="fusion-preset-create"]').click()

    await vi.waitFor(() => expect(applyMock).toHaveBeenCalledTimes(1))
    expect(applyMock.mock.calls[0]).toEqual(['rev-1', { kind: 'upsert_preset', preset: preset('trio-copy') }])
    await savedNotice()
    expect(select('[data-testid="fusion-preset-select"]').value).toBe('trio-copy')
    expect(input('[data-testid="fusion-preset-name"]').value).toBe('trio-copy')
  })

  it('refuses to create a preset under a name that already exists', async () => {
    await mount()
    await typeInto('[data-testid="fusion-preset-name"]', 'duo')
    button('[data-testid="fusion-preset-create"]').click()

    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-error"]')).not.toBeNull())
    expect(q('[data-testid="fusion-settings-error"]')?.textContent).toContain('duo')
    expect(applyMock).not.toHaveBeenCalled()
  })

  it('renames with rename_preset, keeps the edited draft, and rereads the moved default', async () => {
    fusionConfigMock
      .mockResolvedValueOnce(snapshot())
      .mockResolvedValueOnce(snapshot({ defaultPreset: 'quartet', presets: [preset('quartet'), preset('duo')] }))
    await mount()
    await typeInto('[data-testid="fusion-panel-label"]', 'wide')
    await typeInto('[data-testid="fusion-preset-name"]', 'quartet')
    button('[data-testid="fusion-preset-rename"]').click()

    await vi.waitFor(() => expect(applyMock).toHaveBeenCalledTimes(1))
    expect(applyMock.mock.calls[0]).toEqual(['rev-1', { kind: 'rename_preset', from: 'trio', to: 'quartet' }])
    await savedNotice()
    expect(select('[data-testid="fusion-preset-select"]').value).toBe('quartet')
    expect(input('[data-testid="fusion-panel-label"]').value).toBe('wide')
    expect(button('[data-testid="fusion-preset-save"]').disabled).toBe(false)
    // Renaming the default moves [fusion].default_preset, so the settings draft
    // must follow the file rather than write the old name back.
    expect(select('[data-testid="fusion-default-preset"]').value).toBe('quartet')
  })

  it('deletes only after confirmation', async () => {
    const confirmSpy = vi.fn(() => false)
    setConfirm(confirmSpy)
    await mount()
    button('[data-testid="fusion-preset-delete"]').click()
    expect(confirmSpy).toHaveBeenCalledTimes(1)
    expect(applyMock).not.toHaveBeenCalled()

    setConfirm(() => true)
    fusionConfigMock.mockResolvedValueOnce(snapshot({ presets: [preset('duo')], defaultPreset: 'duo' }))
    button('[data-testid="fusion-preset-delete"]').click()
    await vi.waitFor(() => expect(applyMock).toHaveBeenCalledTimes(1))
    expect(applyMock.mock.calls[0]).toEqual(['rev-1', { kind: 'delete_preset', name: 'trio' }])
    await savedNotice()
    expect(select('[data-testid="fusion-preset-select"]').value).toBe('duo')
  })

  it('rejects a malformed number locally and does not POST', async () => {
    await mount()
    await typeInto('[data-testid="fusion-min-answered"]', '0')
    button('[data-testid="fusion-preset-save"]').click()

    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-error"]')).not.toBeNull())
    expect(q('[data-testid="fusion-settings-error"]')?.textContent).toContain('min_answered')
    expect(applyMock).not.toHaveBeenCalled()

    await typeInto('[data-testid="fusion-staged-judge-group-size"]', '2.5')
    button('[data-testid="fusion-settings-save"]').click()
    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-error"]')?.textContent)
      .toContain('staged_judge_group_size'))
    expect(applyMock).not.toHaveBeenCalled()
  })

  it('opens an empty draft when the config declares no preset', async () => {
    fusionConfigMock.mockResolvedValue(snapshot({ presets: [], defaultPreset: '', enabled: false }))
    await mount()
    expect(input('[data-testid="fusion-preset-name"]').value).toBe('')
    expect(qa('[data-testid="fusion-panel-group"]')).toHaveLength(1)
    expect(button('[data-testid="fusion-preset-save"]').disabled).toBe(true)
    expect(button('[data-testid="fusion-preset-delete"]').disabled).toBe(true)
    expect(q('[data-testid="fusion-preset-view"]')).toBeNull()
  })

  it('surfaces load failures instead of staying on the loading guard', async () => {
    fusionConfigMock.mockRejectedValue(new Error('network down'))
    const { FusionSettingsPanel } = await import('./fusion-settings-panel')
    render(h(FusionSettingsPanel, {}), container)

    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-error"]')).not.toBeNull())
    expect(q('[data-testid="fusion-settings-loading"]')).toBeNull()
    expect(q('[data-testid="fusion-settings-error"]')?.textContent).toContain('network down')
  })
})
