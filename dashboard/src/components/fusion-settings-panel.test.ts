import { h, render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const SAMPLE = `[fusion]
enabled = true
default_preset = "trio"

[fusion.gate]
per_hour_budget = 20

[fusion.presets.trio]
panel = ["a", "b", "c"]
judge = "j"
min_answered = 2
`

const SAMPLE_WITH_DUO = `${SAMPLE}
[fusion.presets.duo]
panel = ["a", "b"]
judge = "j"
min_answered = 1
`

const SAMPLE_WITH_RUNTIME_OPTIONS = `${SAMPLE}
[new.x]
is-default = false

[meta.judge]
is-default = false
`

const cfg = (over: { ok?: boolean; source_text?: string; reloaded?: boolean }) => ({
  ok: over.ok ?? true,
  path: null,
  file_name: 'runtime.toml',
  source_text: over.source_text ?? SAMPLE,
  reloaded: over.reloaded ?? false,
})

const fetchMock = vi.fn()
const saveMock = vi.fn()
const runtimeRefreshMock = vi.fn(async () => undefined)
vi.mock('../api/dashboard', () => ({
  fetchRuntimeTomlConfig: () => fetchMock(),
  saveRuntimeTomlConfig: (text: string) => saveMock(text),
}))
vi.mock('../lib/runtime-config-refresh', () => ({
  refreshRuntimeConfigConsumers: () => runtimeRefreshMock(),
}))

let container: HTMLDivElement
const q = (sel: string) => container.querySelector(sel)

beforeEach(() => {
  fetchMock.mockReset()
  saveMock.mockReset()
  runtimeRefreshMock.mockClear()
  container = document.createElement('div')
  document.body.appendChild(container)
})
afterEach(() => {
  render(null, container)
  container.remove()
})

async function mount() {
  const { FusionSettingsPanel } = await import('./fusion-settings-panel')
  render(h(FusionSettingsPanel, {}), container)
  await vi.waitFor(() => expect(q('[data-testid="fusion-settings-editor"]')).not.toBeNull())
}

describe('FusionSettingsPanel', () => {
  it('loads live config and renders the editor with the current min_answered', async () => {
    fetchMock.mockResolvedValue(cfg({ source_text: SAMPLE }))
    await mount()
    const minInput = q('[data-testid="fusion-min-answered"]') as HTMLInputElement
    expect(minInput.value).toBe('2')
  })

  it('save posts the applied runtime.toml text (min_answered in the preset table)', async () => {
    fetchMock.mockResolvedValue(cfg({ source_text: SAMPLE }))
    saveMock.mockResolvedValue(cfg({ ok: true, reloaded: true }))
    await mount()
    ;(q('[data-testid="fusion-settings-save"]') as HTMLButtonElement).click()
    await vi.waitFor(() => expect(saveMock).toHaveBeenCalledTimes(1))
    const posted = saveMock.mock.calls[0]?.[0] as string
    expect(posted.split('[fusion.presets.trio]')[1]).toContain('min_answered = 2')
    expect(runtimeRefreshMock).toHaveBeenCalledTimes(1)
  })

  it('edits the active flat preset panel runtimes and judge runtime', async () => {
    fetchMock.mockResolvedValue(cfg({ source_text: SAMPLE_WITH_RUNTIME_OPTIONS }))
    saveMock.mockImplementation(async (sourceText: string) => cfg({ ok: true, reloaded: true, source_text: sourceText }))
    await mount()

    const add = q('[data-testid="fusion-panel-runtime-add"]') as HTMLSelectElement
    add.value = 'new.x'
    await fireEvent.change(add)

    const judge = q('[data-testid="fusion-judge-runtime"]') as HTMLSelectElement
    judge.value = 'meta.judge'
    await fireEvent.change(judge)

    ;(q('[data-testid="fusion-settings-save"]') as HTMLButtonElement).click()
    await vi.waitFor(() => expect(saveMock).toHaveBeenCalledTimes(1))
    const posted = saveMock.mock.calls[0]?.[0] as string
    const trio = posted.split('[fusion.presets.trio]')[1] ?? ''
    expect(trio).toContain('panel = ["a", "b", "c", "new.x"]')
    expect(trio).toContain('judge = "meta.judge"')
    expect(runtimeRefreshMock).toHaveBeenCalledTimes(1)
  })

  it('surfaces a backend validation rejection (ok=false) instead of claiming success', async () => {
    fetchMock.mockResolvedValue(cfg({ source_text: SAMPLE }))
    saveMock.mockResolvedValue({
      ...cfg({ ok: false }),
      message: 'Runtime config validation failed',
      reason: 'min_answered exceeds preset panel count',
      issues: [{ key: 'fusion.presets.trio.min_answered', message: 'must be <= 2' }],
    })
    await mount()
    ;(q('[data-testid="fusion-settings-save"]') as HTMLButtonElement).click()
    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-error"]')).not.toBeNull())
    expect(q('[data-testid="fusion-settings-error"]')?.textContent).toContain('fusion.presets.trio.min_answered')
    expect(q('[data-testid="fusion-settings-error"]')?.textContent).toContain('must be <= 2')
    expect(q('[data-testid="fusion-settings-saved"]')).toBeNull()
  })

  it('uses the selected preset existing min_answered when default_preset changes', async () => {
    fetchMock.mockResolvedValue(cfg({ source_text: SAMPLE_WITH_DUO }))
    saveMock.mockResolvedValue(cfg({
      ok: true,
      reloaded: false,
      source_text: SAMPLE_WITH_DUO.replace('default_preset = "trio"', 'default_preset = "duo"'),
    }))
    await mount()
    const presetInput = q('input[type="text"]') as HTMLInputElement
    const minInput = q('[data-testid="fusion-min-answered"]') as HTMLInputElement
    expect(minInput.value).toBe('2')

    presetInput.value = 'duo'
    await fireEvent.input(presetInput)

    expect(minInput.value).toBe('1')
    ;(q('[data-testid="fusion-settings-save"]') as HTMLButtonElement).click()
    await vi.waitFor(() => expect(saveMock).toHaveBeenCalledTimes(1))
    const posted = saveMock.mock.calls[0]?.[0] as string
    expect(posted).toContain('default_preset = "duo"')
    expect(posted.split('[fusion.presets.duo]')[1]).toContain('min_answered = 1')
  })

  it('does not claim reload when backend saved without reload', async () => {
    fetchMock.mockResolvedValue(cfg({ source_text: SAMPLE }))
    saveMock.mockResolvedValue(cfg({ ok: true, reloaded: false }))
    await mount()
    ;(q('[data-testid="fusion-settings-save"]') as HTMLButtonElement).click()
    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-saved"]')).not.toBeNull())
    expect(q('[data-testid="fusion-settings-saved"]')?.textContent).toBe('저장됨')
  })

  it('does not POST whitespace-only default_preset values', async () => {
    fetchMock.mockResolvedValue(cfg({ source_text: SAMPLE }))
    await mount()
    const presetInput = q('input[type="text"]') as HTMLInputElement
    presetInput.value = '   '
    await fireEvent.input(presetInput)

    ;(q('[data-testid="fusion-settings-save"]') as HTMLButtonElement).click()
    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-error"]')?.textContent).toContain('default_preset'))
    expect(saveMock).not.toHaveBeenCalled()
  })

  it('surfaces malformed live TOML instead of rendering fallback values', async () => {
    fetchMock.mockResolvedValue(cfg({ source_text: '[fusion]\nenabled = maybe\n' }))
    const { FusionSettingsPanel } = await import('./fusion-settings-panel')
    render(h(FusionSettingsPanel, {}), container)

    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-error"]')).not.toBeNull())
    expect(q('[data-testid="fusion-settings-editor"]')).toBeNull()
    expect(q('[data-testid="fusion-settings-error"]')?.textContent).toContain('fusion.enabled')
  })

  it('surfaces fetch failures instead of staying on the loading guard', async () => {
    fetchMock.mockRejectedValue(new Error('network down'))
    const { FusionSettingsPanel } = await import('./fusion-settings-panel')
    render(h(FusionSettingsPanel, {}), container)

    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-error"]')).not.toBeNull())
    expect(q('[data-testid="fusion-settings-loading"]')).toBeNull()
    expect(q('[data-testid="fusion-settings-error"]')?.textContent).toContain('network down')
  })

  it('renders the read-only preset composition parsed from the loaded config', async () => {
    fetchMock.mockResolvedValue(cfg({ source_text: SAMPLE }))
    await mount()

    expect(q('[data-testid="fusion-preset-view"]')).not.toBeNull()
    const models = Array.from(container.querySelectorAll('[data-testid="fusion-preset-panel-model"]')).map(m => m.textContent)
    expect(models).toEqual(['a', 'b', 'c'])
    expect(q('[data-testid="fusion-preset-judge"]')?.textContent).toBe('j')
    // SAMPLE's trio declares no timeouts → shown as '—', never fabricated.
    const timing = q('[data-testid="fusion-preset-timing"]')?.textContent ?? ''
    expect(timing).toContain('panel_timeout —')
    expect(timing).toContain('judge_timeout —')
  })

  it('omits the preset card when the default preset has no backing section', async () => {
    // enabled=false keeps the editor valid even though default_preset is unknown;
    // the read-only card is data-driven, so it must not appear.
    const noSection = `[fusion]
enabled = false
default_preset = "ghost"
`
    fetchMock.mockResolvedValue(cfg({ source_text: noSection }))
    await mount()

    expect(q('[data-testid="fusion-settings-editor"]')).not.toBeNull()
    expect(q('[data-testid="fusion-preset-view"]')).toBeNull()
  })

  it('omits the preset card when the preset declares no panel models', async () => {
    // A preset with only min_answered has no composition to display; the card is
    // gated on panel models so the live writer stays lane-free for such configs.
    const noPanel = `[fusion]
enabled = true
default_preset = "trio"

[fusion.presets.trio]
min_answered = 2
`
    fetchMock.mockResolvedValue(cfg({ source_text: noPanel }))
    await mount()

    expect(q('[data-testid="fusion-settings-editor"]')).not.toBeNull()
    expect(q('[data-testid="fusion-preset-view"]')).toBeNull()
    expect(q('[data-testid="fusion-preset-composition-editor"]')).not.toBeNull()
    expect(container.querySelectorAll('.set-fus-lane').length).toBe(0)
  })

  it('does not synthesize an empty panel array on unchanged no-panel preset saves', async () => {
    const noPanel = `[fusion]
enabled = true
default_preset = "trio"

[fusion.presets.trio]
min_answered = 2
`
    fetchMock.mockResolvedValue(cfg({ source_text: noPanel }))
    saveMock.mockImplementation(async (sourceText: string) => cfg({ ok: true, reloaded: true, source_text: sourceText }))
    await mount()

    ;(q('[data-testid="fusion-settings-save"]') as HTMLButtonElement).click()
    await vi.waitFor(() => expect(saveMock).toHaveBeenCalledTimes(1))
    const posted = saveMock.mock.calls[0]?.[0] as string
    const trio = posted.split('[fusion.presets.trio]')[1] ?? ''
    expect(trio).toContain('min_answered = 2')
    expect(trio).not.toContain('panel = []')
  })

  it('shows a fail-visible note (not a partial panel) for grouped presets', async () => {
    const grouped = `[fusion]
enabled = true
default_preset = "mixed"

[fusion.presets.mixed]
judge = "j"
[[fusion.presets.mixed.panels]]
panel = ["fast1", "fast2"]
[[fusion.presets.mixed.panels]]
panel = ["careful1"]
`
    fetchMock.mockResolvedValue(cfg({ source_text: grouped }))
    await mount()

    expect(q('[data-testid="fusion-settings-editor"]')).not.toBeNull()
    // Grouped note shown; the flat lane card is NOT rendered.
    expect(q('[data-testid="fusion-preset-grouped"]')?.textContent).toContain('2개 그룹')
    expect(q('[data-testid="fusion-preset-composition-editor"]')).toBeNull()
    expect(q('[data-testid="fusion-preset-view"]')).toBeNull()
    expect(container.querySelectorAll('.set-fus-lane').length).toBe(0)
    // Must never leak the first group's model as the preset panel (the P1 bug).
    expect(container.textContent).not.toContain('fast1')
  })

  it('renders a flat-panel preset with a judge-of-judges note when first-pass judges exist', async () => {
    const quorumLike = `[fusion]
enabled = true
default_preset = "quorum"

[fusion.presets.quorum]
panel = ["p1", "p2"]
judge = "meta_model"
[[fusion.presets.quorum.judges]]
model = "evidence_model"
[[fusion.presets.quorum.judges]]
model = "coverage_model"
`
    fetchMock.mockResolvedValue(cfg({ source_text: quorumLike }))
    await mount()

    // Flat panels are shown normally.
    expect(q('[data-testid="fusion-preset-view"]')).not.toBeNull()
    const models = Array.from(container.querySelectorAll('[data-testid="fusion-preset-panel-model"]')).map(m => m.textContent)
    expect(models).toEqual(['p1', 'p2'])
    expect(q('[data-testid="fusion-preset-judge"]')?.textContent).toBe('meta_model')
    // The judge lane honestly notes the first-pass judges rather than implying one.
    expect(q('[data-testid="fusion-preset-judge-lane-h"]')?.textContent).toContain('1차 심판 2')
    expect(q('[data-testid="fusion-preset-composition-editor"]')?.textContent).toContain('Judge-of-judges runtime')
  })
})
