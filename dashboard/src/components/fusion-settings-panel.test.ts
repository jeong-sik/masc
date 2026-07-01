import { h, render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const SAMPLE = `[fusion]
enabled = true
default_preset = "trio"
max_concurrent_panels = 2

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
    fetchMock.mockResolvedValue(cfg({ source_text: '[fusion]\nenabled = maybe\nmax_concurrent_panels = 1.5\n' }))
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

  it('does not POST empty or fractional number inputs', async () => {
    fetchMock.mockResolvedValue(cfg({ source_text: SAMPLE }))
    await mount()
    const maxInput = q('[data-testid="fusion-max-concurrent-panels"]') as HTMLInputElement
    maxInput.value = ''
    await fireEvent.input(maxInput)

    ;(q('[data-testid="fusion-settings-save"]') as HTMLButtonElement).click()
    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-error"]')).not.toBeNull())
    expect(saveMock).not.toHaveBeenCalled()

    maxInput.value = '1.5'
    await fireEvent.input(maxInput)
    ;(q('[data-testid="fusion-settings-save"]') as HTMLButtonElement).click()
    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-error"]')?.textContent).toContain('정수'))
    expect(saveMock).not.toHaveBeenCalled()
  })
})
