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

const richSourceText = `[runtime]
default = "runpod_mtp.qwen"

[providers.runpod_mtp]
display-name = "RunPod"
protocol = "provider_d-http"
endpoint = "https://runpod.example/v1"

[providers.runpod_mtp.credentials]
type = "env"
key = "RUNPOD_API_KEY"

[providers.openai]
display-name = "OpenAI"
protocol = "provider_d-http"
endpoint = "https://api.openai.example/v1"

[models.qwen]
api-name = "qwen"
max-context = 128000
tools-support = true
thinking-support = true
streaming = true

[models.gpt]
api-name = "gpt"
max-context = 64000
tools-support = true
streaming = true

[runpod_mtp.qwen]
is-default = true
max-concurrent = 4
keep-alive = "10m"

[openai.gpt]
is-default = true
max-concurrent = 1
`

const richConfig = {
  ...baseConfig,
  source_text: richSourceText,
}

describe('RuntimeTomlEditor', () => {
  let container: HTMLDivElement
  const realClipboard = typeof navigator !== 'undefined' ? navigator.clipboard : undefined
  const realConfirm = window.confirm

  function setClipboard(value: { writeText: (t: string) => Promise<void> } | undefined): void {
    Object.defineProperty(navigator, 'clipboard', {
      value,
      configurable: true,
      writable: true,
    })
  }

  function setConfirm(value: ((message?: string) => boolean) | undefined): void {
    Object.defineProperty(window, 'confirm', {
      value,
      configurable: true,
      writable: true,
    })
  }

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
    setClipboard(realClipboard as unknown as { writeText: (t: string) => Promise<void> } | undefined)
    setConfirm(realConfirm)
    vi.restoreAllMocks()
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
    expect(container.querySelector('[data-testid="runtime-toml-line-numbers"]')?.textContent).toBe('1\n2\n3')
    expect(container.querySelector('[data-testid="runtime-toml-stats"]')?.textContent).toContain('3 lines')
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

  it('edits runtime environment fields through the structured controls', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.textContent).toContain('런타임 환경')
      expect(container.textContent).toContain('런타임 카탈로그')
      expect(container.textContent).toContain('128K ctx')
      expect(container.textContent).toContain('tools:on')
      expect((container.querySelector('[aria-label="provider transport value"]') as HTMLInputElement | null)?.value)
        .toBe('https://runpod.example/v1')
    })

    fireEvent.input(container.querySelector('[aria-label="provider transport value"]') as HTMLInputElement, {
      target: { value: 'https://runpod.example/v2' },
    })
    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toContain('endpoint = "https://runpod.example/v2"')
    })
    fireEvent.input(container.querySelector('[aria-label="model max-context"]') as HTMLInputElement, {
      target: { value: '262144' },
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-environment-save"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    })
    const savedSource = apiMocks.saveRuntimeTomlConfig.mock.calls[0]?.[0] as string
    expect(savedSource).toContain('endpoint = "https://runpod.example/v2"')
    expect(savedSource).toContain('max-context = 262144')
    expect(savedSource).toContain('[providers.openai]')
  })

  it('switches the default runtime from the structured runtime selector', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect((container.querySelector('[aria-label="default runtime"]') as HTMLSelectElement | null)?.value)
        .toBe('runpod_mtp.qwen')
    })

    fireEvent.change(container.querySelector('[aria-label="default runtime"]') as HTMLSelectElement, {
      target: { value: 'openai.gpt' },
    })

    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toContain('default = "openai.gpt"')
    })
    expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('modified')
  })

  it('saves from the editor keyboard shortcut', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement | null)?.value).toBe(baseConfig.source_text)
    })

    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    const nextSource = `${baseConfig.source_text}# keyboard\n`
    fireEvent.input(textarea, { target: { value: nextSource } })
    fireEvent.keyDown(textarea, { key: 's', metaKey: true })

    await waitFor(() => {
      expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledWith(nextSource)
    })
  })

  it('inserts two spaces for tab indentation without leaving the editor', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement | null)?.value).toBe(baseConfig.source_text)
    })

    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    textarea.setSelectionRange('[runtime]\n'.length, '[runtime]\n'.length)
    fireEvent.keyDown(textarea, { key: 'Tab' })

    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toBe(
        '[runtime]\n  default = "runpod_mtp.qwen"\n',
      )
    })
    expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('modified')
  })

  it('guards refresh when the draft has unsaved changes', async () => {
    const confirmSpy = vi.fn(() => false)
    setConfirm(confirmSpy)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement | null)?.value).toBe(baseConfig.source_text)
    })

    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: `${baseConfig.source_text}# unsaved\n` } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-refresh"]') as HTMLButtonElement)

    expect(confirmSpy).toHaveBeenCalledTimes(1)
    expect(apiMocks.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toBe(`${baseConfig.source_text}# unsaved\n`)
  })

  it('refreshes a clean draft without prompting for discard confirmation', async () => {
    const confirmSpy = vi.fn(() => false)
    setConfirm(confirmSpy)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement | null)?.value).toBe(baseConfig.source_text)
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-refresh"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(apiMocks.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(2)
    })
    expect(confirmSpy).not.toHaveBeenCalled()
  })

  it('resets the draft to the last loaded source without calling save', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement | null)?.value).toBe(baseConfig.source_text)
    })

    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: `${baseConfig.source_text}# local\n` } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-reset"]') as HTMLButtonElement)

    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toBe(baseConfig.source_text)
      expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('saved')
    })
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
  })

  it('copies the resolved runtime.toml path', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    setClipboard({ writeText })
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.textContent).toContain('/tmp/.masc/config/runtime.toml')
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-copy-path"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(writeText).toHaveBeenCalledWith('/tmp/.masc/config/runtime.toml')
      expect(container.textContent).toContain('경로 복사됨')
    })
  })

  it('registers a beforeunload guard only while the draft is dirty', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement | null)?.value).toBe(baseConfig.source_text)
    })

    const cleanEvent = new Event('beforeunload', { cancelable: true })
    window.dispatchEvent(cleanEvent)
    expect(cleanEvent.defaultPrevented).toBe(false)

    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: `${baseConfig.source_text}# dirty\n` } })

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('modified')
    })

    const dirtyEvent = new Event('beforeunload', { cancelable: true })
    window.dispatchEvent(dirtyEvent)
    expect(dirtyEvent.defaultPrevented).toBe(true)
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
