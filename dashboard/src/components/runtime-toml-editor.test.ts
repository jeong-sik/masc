import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchRuntimeTomlConfig: vi.fn(),
  saveRuntimeTomlConfig: vi.fn(),
}))

vi.mock('../api/dashboard', () => ({
  fetchRuntimeTomlConfig: apiMocks.fetchRuntimeTomlConfig,
  saveRuntimeTomlConfig: apiMocks.saveRuntimeTomlConfig,
}))

import { RuntimeTomlEditor } from './runtime-toml-editor'

const baseConfig = {
  ok: true,
  path: '/tmp/.masc/config/runtime.toml',
  file_name: 'runtime.toml',
  source_text: '[runtime]\ndefault = "runpod_mtp.qwen"\n',
  reloaded: false,
}

describe('RuntimeTomlEditor', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    apiMocks.fetchRuntimeTomlConfig.mockReset()
    apiMocks.saveRuntimeTomlConfig.mockReset()
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValue(baseConfig)
    apiMocks.saveRuntimeTomlConfig.mockImplementation(async (sourceText: string) => ({
      ...baseConfig,
      source_text: sourceText,
      reloaded: true,
    }))
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('loads and displays the full runtime.toml source', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(apiMocks.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(1)
      expect(container.textContent).toContain('/tmp/.masc/config/runtime.toml')
    })

    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    const saveButton = container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement

    expect(textarea.value).toBe(baseConfig.source_text)
    expect(saveButton.disabled).toBe(true)
    expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('saved')
  })

  it('saves the edited TOML source and clears the dirty state', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement | null)?.value).toBe(baseConfig.source_text)
    })

    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    const saveButton = container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement
    const nextSource = `${baseConfig.source_text}\n[runtime.assignments]\nsangsu = "runpod_mtp.qwen"\n`

    fireEvent.input(textarea, { target: { value: nextSource } })

    await waitFor(() => {
      expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(false)
      expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('modified')
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledWith(nextSource)
      expect(container.textContent).toContain('저장됨')
    })
    expect(saveButton.disabled).toBe(true)
    expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toBe(nextSource)
  })

  it('shows load errors without losing the editor surface', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockRejectedValueOnce(new Error('runtime config path not found'))

    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.textContent).toContain('runtime config path not found')
    })
    expect(container.querySelector('textarea')).not.toBeNull()
  })

  it('keeps the dirty draft when save validation fails', async () => {
    apiMocks.saveRuntimeTomlConfig.mockRejectedValueOnce(new Error('runtime config parse failed'))
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement | null)?.value).toBe(baseConfig.source_text)
    })

    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    const saveButton = container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement
    fireEvent.input(textarea, { target: { value: '[runtime]\ndefault = "missing.runtime"\n' } })
    fireEvent.click(saveButton)

    await waitFor(() => {
      expect(container.textContent).toContain('runtime config parse failed')
    })
    expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toBe('[runtime]\ndefault = "missing.runtime"\n')
    expect(saveButton.disabled).toBe(false)
  })
})
