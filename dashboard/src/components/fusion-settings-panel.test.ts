import { h, render } from 'preact'
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

const cfg = (over: { ok?: boolean; source_text?: string; reloaded?: boolean }) => ({
  ok: over.ok ?? true,
  path: null,
  file_name: 'runtime.toml',
  source_text: over.source_text ?? SAMPLE,
  reloaded: over.reloaded ?? false,
})

const fetchMock = vi.fn()
const saveMock = vi.fn()
vi.mock('../api/dashboard', () => ({
  fetchRuntimeTomlConfig: () => fetchMock(),
  saveRuntimeTomlConfig: (text: string) => saveMock(text),
}))

let container: HTMLDivElement
const q = (sel: string) => container.querySelector(sel)

beforeEach(() => {
  fetchMock.mockReset()
  saveMock.mockReset()
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
  })

  it('surfaces a backend validation rejection (ok=false) instead of claiming success', async () => {
    fetchMock.mockResolvedValue(cfg({ source_text: SAMPLE }))
    saveMock.mockResolvedValue(cfg({ ok: false }))
    await mount()
    ;(q('[data-testid="fusion-settings-save"]') as HTMLButtonElement).click()
    await vi.waitFor(() => expect(q('[data-testid="fusion-settings-error"]')).not.toBeNull())
    expect(q('[data-testid="fusion-settings-saved"]')).toBeNull()
  })
})
