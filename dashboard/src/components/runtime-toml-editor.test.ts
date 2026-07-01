import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchRuntimeTomlConfig: vi.fn(),
  patchRuntimeAssignment: vi.fn(),
  patchRuntimeRouting: vi.fn(),
  saveRuntimeTomlConfig: vi.fn(),
}))

vi.mock('../api/dashboard', () => ({
  fetchRuntimeTomlConfig: apiMocks.fetchRuntimeTomlConfig,
  patchRuntimeAssignment: apiMocks.patchRuntimeAssignment,
  patchRuntimeRouting: apiMocks.patchRuntimeRouting,
  saveRuntimeTomlConfig: apiMocks.saveRuntimeTomlConfig,
}))

import { RuntimeTomlEditor } from './runtime-toml-editor'

const MOCK_RUNTIME_PATH = '/tmp/.masc/config/runtime.toml'

const baseConfig = {
  ok: true,
  path: MOCK_RUNTIME_PATH,
  file_name: 'runtime.toml',
  source_text: '[runtime]\ndefault = "runpod_mtp.qwen"\n',
  reloaded: false,
}

const richSourceText = `[runtime]
default = "runpod_mtp.qwen"

[providers.runpod_mtp]
display-name = "RunPod"
protocol = "openai-http"
endpoint = "https://runpod.example/v1"

[providers.runpod_mtp.credentials]
type = "env"
key = "RUNPOD_API_KEY"

[providers.openai]
display-name = "OpenAI"
protocol = "openai-http"
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
    apiMocks.patchRuntimeAssignment.mockReset()
    apiMocks.patchRuntimeRouting.mockReset()
    apiMocks.saveRuntimeTomlConfig.mockReset()
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValue(baseConfig)
    apiMocks.patchRuntimeAssignment.mockImplementation(async (_keeperName: string, runtimeId: string | null) => ({
      ...richConfig,
      source_text: `${richConfig.source_text}\n[runtime.assignments]\nsangsu = ${JSON.stringify(runtimeId ?? 'runpod_mtp.qwen')}\n`,
      reloaded: true,
    }))
    apiMocks.patchRuntimeRouting.mockImplementation(async (lane: string, runtimeId: string | null) => ({
      ...richConfig,
      source_text: richConfig.source_text.replace(
        'default = "runpod_mtp.qwen"',
        lane === 'default' && runtimeId ? `default = "${runtimeId}"` : 'default = "runpod_mtp.qwen"',
      ),
      reloaded: true,
    }))
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
      expect(container.textContent).toContain(MOCK_RUNTIME_PATH)
    })

    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    const saveButton = container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement

    expect(textarea.value).toBe(baseConfig.source_text)
    expect(saveButton.disabled).toBe(true)
    expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('saved')
    expect(container.querySelector('[data-testid="runtime-toml-line-numbers"]')?.textContent).toBe('1\n2\n3')
    expect(container.querySelector('[data-testid="runtime-toml-stats"]')?.textContent).toContain('3 lines')
    expect(container.querySelector('[data-testid="runtime-toml-code-frame"]')?.classList.contains('v2-monitoring-code-frame')).toBe(true)
    expect(container.querySelector('.v2-monitoring-toolbar')).not.toBeNull()
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
    expect(container.querySelector('[data-testid="runtime-toml-impact-preview"]')?.textContent).toContain('적용 미리보기')
    expect(container.querySelector('[data-testid="runtime-toml-default-impact"]')?.textContent).toContain('default unchanged')
    expect(container.querySelector('[data-testid="runtime-toml-assignments-impact"]')?.textContent).toContain('assignments changed')

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledWith(nextSource)
      expect(container.textContent).toContain('적용됨')
    })
    expect(saveButton.disabled).toBe(true)
    expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toBe(nextSource)
    expect(container.querySelector('[data-testid="runtime-toml-impact-preview"]')).toBeNull()
  })

  it('renders runtime environment fields as structured projections without raw TOML mutation', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.textContent).toContain('런타임 환경')
      // The prototype models section renders each model read-only: id + context
      // (protoContext → "128k ctx") + capability chips. Model facts stay
      // read-only; runtime execution knobs are edited per binding instead.
      const modelsSection = container.querySelector('[data-testid="runtime-section-models"]')
      expect(modelsSection?.textContent).toContain('qwen')
      expect(modelsSection?.textContent).toContain('128k ctx')
      expect((container.querySelector('[aria-label="provider transport value"]') as HTMLInputElement | null)?.value)
        .toBe('https://runpod.example/v1')
    })

    expect((container.querySelector('[aria-label="provider transport value"]') as HTMLInputElement).readOnly).toBe(true)
    expect(container.querySelector('[data-testid="runtime-environment-save"]')).toBeNull()
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
  })

  it('edits binding runtime knobs as a draft and applies them through the existing save path', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-bindings"]')).not.toBeNull()
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-bindings"]') as HTMLButtonElement)

    const maxConcurrent = container.querySelector('[aria-label="runpod_mtp.qwen max-concurrent"]') as HTMLInputElement
    const keepAlive = container.querySelector('[aria-label="runpod_mtp.qwen keep-alive"]') as HTMLInputElement
    const numCtx = container.querySelector('[aria-label="runpod_mtp.qwen num-ctx"]') as HTMLInputElement

    expect(maxConcurrent.readOnly).toBe(false)
    expect(maxConcurrent.disabled).toBe(false)
    expect(maxConcurrent.value).toBe('4')
    expect(keepAlive.value).toBe('10m')

    fireEvent.input(maxConcurrent, { target: { value: '6' } })
    fireEvent.input(keepAlive, { target: { value: '20m' } })
    fireEvent.input(numCtx, { target: { value: '262144' } })

    await waitFor(() => {
      const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
      expect(source).toContain('max-concurrent = 6')
      expect(source).toContain('keep-alive = "20m"')
      expect(source).toContain('num-ctx = 262144')
      expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('modified')
      expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(false)
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)

    await waitFor(() => {
      const savedSource = apiMocks.saveRuntimeTomlConfig.mock.calls[0]?.[0] as string
      expect(savedSource).toContain('max-concurrent = 6')
      expect(savedSource).toContain('keep-alive = "20m"')
      expect(savedSource).toContain('num-ctx = 262144')
      expect(container.textContent).toContain('적용됨')
    })
    expect(apiMocks.patchRuntimeRouting).not.toHaveBeenCalled()
    expect(apiMocks.patchRuntimeAssignment).not.toHaveBeenCalled()
  })

  it('ignores invalid binding number edits without dirtying the draft', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-bindings"]')).not.toBeNull()
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-bindings"]') as HTMLButtonElement)

    const textarea = container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement
    const maxConcurrent = container.querySelector('[aria-label="runpod_mtp.qwen max-concurrent"]') as HTMLInputElement
    const numCtx = container.querySelector('[aria-label="runpod_mtp.qwen num-ctx"]') as HTMLInputElement

    expect(textarea.value).toBe(richSourceText)
    fireEvent.input(maxConcurrent, { target: { value: '0' } })
    fireEvent.input(numCtx, { target: { value: '-1' } })

    await waitFor(() => {
      expect((container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value)
        .toBe(richSourceText)
      expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('saved')
      expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(true)
    })
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    expect(apiMocks.patchRuntimeRouting).not.toHaveBeenCalled()
    expect(apiMocks.patchRuntimeAssignment).not.toHaveBeenCalled()
  })

  it('switches the default runtime through the typed backend routing patch', async () => {
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
      expect(apiMocks.patchRuntimeRouting).toHaveBeenCalledWith('default', 'openai.gpt')
      expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toContain('default = "openai.gpt"')
    })
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('saved')
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
      expect(container.textContent).toContain(MOCK_RUNTIME_PATH)
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-copy-path"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(writeText).toHaveBeenCalledWith(MOCK_RUNTIME_PATH)
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

  it('renders all six section-nav entries with the prototype labels', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-routing"]')).not.toBeNull()
    })

    const nav = container.querySelector('nav.rt-nav') as HTMLElement
    expect(nav.getAttribute('aria-label')).toBe('런타임 편집기 섹션')

    const expected: Array<[string, string]> = [
      ['routing', '라우팅'],
      ['providers', '프로바이더'],
      ['models', '모델'],
      ['bindings', '바인딩 · 런타임 id'],
      ['assignments', 'keeper 배정'],
      ['toml', 'runtime.toml'],
    ]
    for (const [id, label] of expected) {
      const button = container.querySelector(`[data-testid="runtime-toml-nav-${id}"]`) as HTMLButtonElement | null
      expect(button, `nav button for ${id}`).not.toBeNull()
      expect(button?.textContent).toContain(label)
    }
  })

  it('defaults to the routing section with the structured editor visible and raw TOML hidden', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-section-title"]')?.textContent).toBe('라우팅')
    })

    const routingNav = container.querySelector('[data-testid="runtime-toml-nav-routing"]') as HTMLButtonElement
    expect(routingNav.getAttribute('aria-pressed')).toBe('true')

    const structured = container.querySelector('[data-testid="runtime-toml-structured"]') as HTMLElement
    const toml = container.querySelector('[data-testid="runtime-toml-section"]') as HTMLElement
    expect(structured.classList.contains('hidden')).toBe(false)
    expect(toml.classList.contains('hidden')).toBe(true)
  })

  it('switches sections from the nav, updating title, aria-pressed and visibility', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-models"]')).not.toBeNull()
    })

    // Switch to a different structured section: title updates, structured stays mounted+visible.
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-models"]') as HTMLButtonElement)
    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-section-title"]')?.textContent).toBe('모델')
    })
    expect((container.querySelector('[data-testid="runtime-toml-nav-models"]') as HTMLButtonElement).getAttribute('aria-pressed')).toBe('true')
    expect((container.querySelector('[data-testid="runtime-toml-nav-routing"]') as HTMLButtonElement).getAttribute('aria-pressed')).toBe('false')
    expect((container.querySelector('[data-testid="runtime-toml-structured"]') as HTMLElement).classList.contains('hidden')).toBe(false)
    expect((container.querySelector('[data-testid="runtime-toml-section"]') as HTMLElement).classList.contains('hidden')).toBe(true)

    // Switch to the raw TOML section: structured hides, raw TOML view becomes visible.
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-toml"]') as HTMLButtonElement)
    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-section-title"]')?.textContent).toBe('runtime.toml')
    })
    expect((container.querySelector('[data-testid="runtime-toml-structured"]') as HTMLElement).classList.contains('hidden')).toBe(true)
    expect((container.querySelector('[data-testid="runtime-toml-section"]') as HTMLElement).classList.contains('hidden')).toBe(false)
  })

  it('keeps the raw-TOML editor path working after navigating into the toml section', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement | null)?.value).toBe(baseConfig.source_text)
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-toml"]') as HTMLButtonElement)
    await waitFor(() => {
      expect((container.querySelector('[data-testid="runtime-toml-section"]') as HTMLElement).classList.contains('hidden')).toBe(false)
    })

    const textarea = container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement
    const nextSource = `${baseConfig.source_text}# edited in toml view\n`
    fireEvent.input(textarea, { target: { value: nextSource } })

    await waitFor(() => {
      expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(false)
      expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('modified')
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)
    await waitFor(() => {
      expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledWith(nextSource)
    })
    expect((container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value).toBe(nextSource)
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

  it('adds a new provider through the form and saves it through the existing validated path', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-providers"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-providers"]') as HTMLButtonElement)
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-toggle"]') as HTMLButtonElement)

    fireEvent.input(container.querySelector('[data-testid="runtime-add-provider-id"]') as HTMLInputElement, {
      target: { value: 'brandnew' },
    })
    fireEvent.input(container.querySelector('[aria-label="새 provider transport 값"]') as HTMLInputElement, {
      target: { value: 'https://brandnew.example/v1' },
    })
    fireEvent.input(container.querySelector('[aria-label="새 provider credential 값"]') as HTMLInputElement, {
      target: { value: 'BRANDNEW_KEY' },
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-submit"]') as HTMLButtonElement)

    await waitFor(() => {
      const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
      expect(source).toContain('[providers.brandnew]')
      expect(source).toContain('endpoint = "https://brandnew.example/v1"')
      expect(source).toContain('[providers.brandnew.credentials]')
      expect(source).toContain('key = "BRANDNEW_KEY"')
      expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('modified')
    })
    // Existing providers untouched.
    expect((container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value)
      .toContain('[providers.runpod_mtp]')

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)
    await waitFor(() => {
      const savedSource = apiMocks.saveRuntimeTomlConfig.mock.calls[0]?.[0] as string
      expect(savedSource).toContain('[providers.brandnew]')
    })
  })

  it('rejects adding a provider whose id already exists without dirtying the draft', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-providers"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-providers"]') as HTMLButtonElement)
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-toggle"]') as HTMLButtonElement)

    fireEvent.input(container.querySelector('[data-testid="runtime-add-provider-id"]') as HTMLInputElement, {
      target: { value: 'runpod_mtp' },
    })
    fireEvent.input(container.querySelector('[aria-label="새 provider transport 값"]') as HTMLInputElement, {
      target: { value: 'https://irrelevant.example/v1' },
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-submit"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-add-provider-error"]')?.textContent)
        .toContain('이미 존재하는')
    })
    expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).not.toContain('modified')
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
  })

  it('adds a new model through the form', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-models"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-models"]') as HTMLButtonElement)
    fireEvent.click(container.querySelector('[data-testid="runtime-add-model-toggle"]') as HTMLButtonElement)

    fireEvent.input(container.querySelector('[data-testid="runtime-add-model-id"]') as HTMLInputElement, {
      target: { value: 'brandnewmodel' },
    })
    fireEvent.input(container.querySelector('[data-testid="runtime-add-model-max-context"]') as HTMLInputElement, {
      target: { value: '50000' },
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-model-submit"]') as HTMLButtonElement)

    await waitFor(() => {
      const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
      expect(source).toContain('[models.brandnewmodel]')
      expect(source).toContain('max-context = 50000')
    })
  })

  it('rejects adding a model with an invalid or missing max-context', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-models"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-models"]') as HTMLButtonElement)
    fireEvent.click(container.querySelector('[data-testid="runtime-add-model-toggle"]') as HTMLButtonElement)

    fireEvent.input(container.querySelector('[data-testid="runtime-add-model-id"]') as HTMLInputElement, {
      target: { value: 'brandnewmodel' },
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-model-submit"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-add-model-error"]')?.textContent)
        .toContain('max-context')
    })
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
  })

  it('adds a new binding pinning an existing provider to an existing model', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-bindings"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-bindings"]') as HTMLButtonElement)

    fireEvent.change(container.querySelector('[data-testid="runtime-add-binding-provider"]') as HTMLSelectElement, {
      target: { value: 'runpod_mtp' },
    })
    fireEvent.change(container.querySelector('[data-testid="runtime-add-binding-model"]') as HTMLSelectElement, {
      target: { value: 'gpt' },
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-binding-submit"]') as HTMLButtonElement)

    await waitFor(() => {
      const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
      expect(source).toContain('[runpod_mtp.gpt]')
    })
  })
})
