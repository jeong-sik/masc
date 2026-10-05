import * as devToken from '../api/dev-token'
import { saveRuntimeTomlConfig as actualSaveRuntimeTomlConfig } from '../api/dashboard-runtime'
import * as coreApi from '../api/core'
import { RuntimeTomlRevisionConflict } from '../api/dashboard-runtime'
import { modelSetupResumeState } from '../lib/model-setup-resume'
import { html } from 'htm/preact'
import { render } from 'preact'
import { act, fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  committedRuntimeTomlConfigFixture,
  runtimeReservedProviderIdsFixture,
} from '../lib/runtime-config-receipt.test-fixture'
import { getRuntimeTomlKey } from '../lib/runtime-toml-config'

const apiMocks = vi.hoisted(() => ({
  fetchRuntimeTomlConfig: vi.fn(),
  fetchRuntimeResolved: vi.fn(),
  fetchStandaloneLanes: vi.fn(),
  patchRuntimeAssignment: vi.fn(),
  patchRuntimeExactSlot: vi.fn(),
  patchRuntimeRouting: vi.fn(),
  saveRuntimeTomlConfig: vi.fn(),
}))

const runtimeRefreshMock = vi.hoisted(() => ({
  refreshRuntimeConfigConsumers: vi.fn(async () => undefined),
}))

vi.mock('../api/dashboard', () => ({
  fetchRuntimeTomlConfig: apiMocks.fetchRuntimeTomlConfig,
  fetchRuntimeResolved: apiMocks.fetchRuntimeResolved,
  fetchStandaloneLanes: apiMocks.fetchStandaloneLanes,
  patchRuntimeAssignment: apiMocks.patchRuntimeAssignment,
  patchRuntimeExactSlot: apiMocks.patchRuntimeExactSlot,
  patchRuntimeRouting: apiMocks.patchRuntimeRouting,
  saveRuntimeTomlConfig: apiMocks.saveRuntimeTomlConfig,
}))

vi.mock('../lib/runtime-config-refresh', () => ({
  refreshRuntimeConfigConsumers: runtimeRefreshMock.refreshRuntimeConfigConsumers,
}))

import { RuntimeTomlEditor } from './runtime-toml-editor'
import { keepers, hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
import { resetRuntimeTomlSessionsForTesting } from '../lib/runtime-toml-session'
let workspaceEpoch = 0
let workspaceGeneration = 0
function workspace(root: string | null) {
  hydrateExecutionSnapshot({ execution_publication_epoch: `runtime-editor-${workspaceEpoch}`,
    execution_publication_generation: ++workspaceGeneration,
    status: { project: 'test', workspace_root: root } } as Parameters<typeof hydrateExecutionSnapshot>[0])
}
import { announceRuntimeTomlWritten } from '../lib/runtime-toml-source-generation'

const MOCK_RUNTIME_PATH = '/tmp/.masc/config/runtime.toml'

const providerProtocols = [
  {
    protocol: 'messages-http',
    transport: 'endpoint',
    semantics: 'http_provider',
    credential_policy: 'optional',
    requires_non_interactive: false,
    provider_fields: [],
    required_provider_fields: [],
  },
  {
    protocol: 'openai-compatible-http',
    transport: 'endpoint',
    semantics: 'http_provider',
    credential_policy: 'optional',
    requires_non_interactive: false,
    provider_fields: [],
    required_provider_fields: [],
  },
  {
    protocol: 'ollama-http',
    transport: 'endpoint',
    semantics: 'http_provider',
    credential_policy: 'optional',
    requires_non_interactive: false,
    provider_fields: [],
    required_provider_fields: [],
  },
  {
    protocol: 'codex-app-server',
    transport: 'command',
    semantics: 'official_client',
    credential_policy: 'forbidden',
    requires_non_interactive: true,
    provider_fields: ['account-home'],
    required_provider_fields: [],
  },
  {
    protocol: 'claude-code',
    transport: 'command',
    semantics: 'official_client',
    credential_policy: 'forbidden',
    requires_non_interactive: true,
    provider_fields: ['account-home'],
    required_provider_fields: [],
  },
  {
    protocol: 'antigravity-cli',
    transport: 'command',
    semantics: 'official_client',
    credential_policy: 'file_required',
    requires_non_interactive: true,
    provider_fields: ['agent', 'effort', 'timeout-s'],
    required_provider_fields: ['timeout-s'],
  },
  {
    protocol: 'muse-serve',
    transport: 'command',
    semantics: 'official_client',
    credential_policy: 'forbidden',
    requires_non_interactive: true,
    provider_fields: ['account-home'],
    required_provider_fields: ['account-home'],
  },
] as const

const baseConfig = {
  ok: true,
  path: MOCK_RUNTIME_PATH,
  file_name: 'runtime.toml',
  source_text: '[runtime]\ndefault = "runpod_mtp.qwen"\n',
  source_revision: 'a'.repeat(64),
  reloaded: false,
  provider_protocols: providerProtocols,
  reserved_provider_ids: [...runtimeReservedProviderIdsFixture],
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

function laneSnapshot(slots = ['runpod_mtp.qwen', 'openai.gpt'], cliSlots = ['codex_subscription.luna']) {
  return { lanes: [
    'board_attention_exact', 'hitl_auto_judge', 'librarian_exact',
    'workspace_curator_exact', 'verifier_exact', 'browser_stagehand_exact', 'candle_appraiser',
  ].map(laneId => ({
    laneId,
    label: laneId,
    declaredSlots: laneId === 'librarian_exact' ? slots : [],
    declaredCliSlots: laneId === 'librarian_exact' ? cliSlots : [],
    droppedSlots: [],
    admissionError: null,
  })) }
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
    resetRuntimeTomlSessionsForTesting()
    const epoch = `runtime-editor-${++workspaceEpoch}`
    invalidateExecutionSnapshotGeneration(epoch, 0)
    workspaceGeneration = 0; workspace('/test/A')
    modelSetupResumeState.value = { kind: 'idle' }
    vi.spyOn(coreApi, 'postControlPlane').mockResolvedValue({ runtime_ready: true,
      exact_output_authority_available: true, model_setup: { status: 'available' } })
    container = document.createElement('div')
    document.body.appendChild(container)
    apiMocks.fetchRuntimeTomlConfig.mockReset()
    apiMocks.fetchRuntimeResolved.mockReset()
    apiMocks.fetchStandaloneLanes.mockReset()
    apiMocks.patchRuntimeAssignment.mockReset()
    apiMocks.patchRuntimeExactSlot.mockReset()
    apiMocks.patchRuntimeRouting.mockReset()
    apiMocks.saveRuntimeTomlConfig.mockReset()
    runtimeRefreshMock.refreshRuntimeConfigConsumers.mockClear()
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValue(baseConfig)
    apiMocks.fetchStandaloneLanes.mockResolvedValue(laneSnapshot())
    apiMocks.fetchRuntimeResolved.mockResolvedValue({ runtimes: [
      { id: 'runpod_mtp.qwen', provider: 'RunPod' },
      { id: 'openai.gpt', provider: 'OpenAI' },
      { id: 'codex_subscription.luna', provider: 'Codex Subscription' },
    ] })
    apiMocks.patchRuntimeExactSlot.mockImplementation(async () =>
      committedRuntimeTomlConfigFixture(richConfig))
    apiMocks.patchRuntimeAssignment.mockImplementation(async (_keeperName: string, runtimeId: string | null) =>
      committedRuntimeTomlConfigFixture({
        ...richConfig,
        source_text: `${richConfig.source_text}\n[runtime.assignments]\nsangsu = ${JSON.stringify(runtimeId ?? 'runpod_mtp.qwen')}\n`,
      }))
    apiMocks.patchRuntimeRouting.mockImplementation(async (lane: string, runtimeId: string | null) => {
      const sourceText = richConfig.source_text.replace(
        'default = "runpod_mtp.qwen"',
        lane === 'default' && runtimeId ? `default = "${runtimeId}"` : 'default = "runpod_mtp.qwen"',
      )
      return committedRuntimeTomlConfigFixture({
        ...richConfig,
        source_text: sourceText,
      })
    })
    apiMocks.saveRuntimeTomlConfig.mockImplementation(async (sourceText: string) =>
      committedRuntimeTomlConfigFixture({
        ...baseConfig,
        source_text: sourceText,
      }))
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    setClipboard(realClipboard as unknown as { writeText: (t: string) => Promise<void> } | undefined)
    setConfirm(realConfirm)
    vi.restoreAllMocks()
    keepers.value = []
  })

  it('retains an unsaved runtime draft and section across component navigation', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect((container.querySelector('textarea') as HTMLTextAreaElement | null)?.value).toBe(baseConfig.source_text))
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-toml"]') as HTMLButtonElement)
    const draft = baseConfig.source_text + '# unsaved operator configuration\n'
    fireEvent.input(container.querySelector('textarea') as HTMLTextAreaElement, { target: { value: draft } })
    render(null, container)
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect((container.querySelector('textarea') as HTMLTextAreaElement | null)?.value).toBe(draft))
    expect(container.querySelector('[data-testid="runtime-toml-nav-toml"]')?.getAttribute('aria-pressed')).toBe('true')
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    expect(apiMocks.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(1)
  })

  it('follows draft edits for an absent navigation target and offers it without moving the caret', async () => {
    const target = { kind: 'browser' as const, lane: 'live' as const, workspace: '/tmp' }
    render(html`<${RuntimeTomlEditor} navigationTarget=${target} />`, container)
    await waitFor(() => expect(container.textContent).toContain('This target is not declared in the current draft'))
    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    const draft = baseConfig.source_text + '[browser.live]\nenabled = true\n'
    fireEvent.input(textarea, { target: { value: draft } })
    textarea.setSelectionRange(draft.length, draft.length)
    const offer = await waitFor(() => {
      const button = [...container.querySelectorAll('button')].find(item => item.textContent === 'Select target')
      expect(button).toBeTruthy()
      return button as HTMLButtonElement
    })
    // The notice follows the text, and the reader's caret is not taken over.
    expect(container.textContent).not.toContain('This target is not declared in the current draft')
    expect(textarea.selectionStart).toBe(draft.length)
    fireEvent.click(offer)
    expect(textarea.selectionStart).toBe(draft.indexOf('[browser.live]'))
    expect(textarea.selectionEnd).toBeGreaterThan(textarea.selectionStart)
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
  })

  it('keeps the unload guard while the dirty editor is unmounted', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    fireEvent.input(container.querySelector('textarea')!, { target: { value: baseConfig.source_text + '# local\n' } })
    render(null, container)
    const event = new Event('beforeunload', { cancelable: true }); window.dispatchEvent(event)
    expect(event.defaultPrevented).toBe(true)
    render(html`<${RuntimeTomlEditor} />`, container)
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-reset"]')!)
    const reset = new Event('beforeunload', { cancelable: true }); window.dispatchEvent(reset)
    expect(reset.defaultPrevented).toBe(false)
  })

  it('settles a save after unmount without losing newer edits or calling a stale parent', async () => {
    let finish!: (saved: ReturnType<typeof committedRuntimeTomlConfigFixture>) => void
    apiMocks.saveRuntimeTomlConfig.mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
    const onSaved = vi.fn()
    render(html`<${RuntimeTomlEditor} onSaved=${onSaved} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    const submitted = baseConfig.source_text + '# submitted\n', newer = submitted + '# newer\n'
    fireEvent.input(container.querySelector('textarea')!, { target: { value: submitted } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]')!)
    await waitFor(() => expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    expect(container.querySelector('textarea')?.disabled).toBe(false)
    fireEvent.input(container.querySelector('textarea')!, { target: { value: newer } })
    render(null, container)
    const saved = committedRuntimeTomlConfigFixture({ ...baseConfig, source_text: submitted })
    await act(async () => { finish(saved); await Promise.resolve() })
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(newer))
    await waitFor(() => expect(container.textContent).toContain('저장 중 추가한 초안'))
    expect(onSaved).not.toHaveBeenCalled()
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]')!)
    await waitFor(() => expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenLastCalledWith(newer, saved.source_revision, expect.any(Object)))
  })

  it('isolates identical file paths across workspaces and compares before saving on return', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    const draftA = baseConfig.source_text + '# workspace A\n'
    fireEvent.input(container.querySelector('textarea')!, { target: { value: draftA } })
    const configB = { ...baseConfig, source_text: baseConfig.source_text + '# server B\n' }
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValue(configB)
    await act(() => workspace('/test/B'))
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(configB.source_text))
    const draftB = configB.source_text + '# local B\n'
    fireEvent.input(container.querySelector('textarea')!, { target: { value: draftB } })
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValue({ ...baseConfig, source_text: baseConfig.source_text + '# external writer A\n', source_revision: 'e'.repeat(64) })
    await act(() => workspace('/test/A'))
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(draftA))
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-conflict"]')).not.toBeNull())
    expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-adopt-revision"]')!)
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValue(configB)
    await act(() => workspace('/test/B'))
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(draftB))
  })

  it('keeps a pending A write uncertain after A-B-A and refuses stale comparison adoption', async () => {
    let finish!: (saved: ReturnType<typeof committedRuntimeTomlConfigFixture>) => void
    apiMocks.saveRuntimeTomlConfig.mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    const draft = baseConfig.source_text + '# pending A\n'
    fireEvent.input(container.querySelector('textarea')!, { target: { value: draft } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]')!)
    await waitFor(() => expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    await act(() => workspace('/test/B'))
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    await act(() => workspace('/test/A'))
    await act(async () => { finish(committedRuntimeTomlConfigFixture({ ...baseConfig, source_text: draft })); await Promise.resolve() })
    await waitFor(() => expect(container.textContent).toContain('작업공간 연결이 바뀌었습니다'))
    expect(container.querySelector('textarea')?.value).toBe(draft)
    expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(true)
    expect(container.querySelector('[data-testid="runtime-toml-adopt-revision"]')).toBeNull()
    expect(coreApi.postControlPlane).not.toHaveBeenCalled()
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-read-current"]')!)
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-adopt-revision"]')).not.toBeNull())
  })

  it.each([false, true])('revalidates same-workspace authority after a held read, dirty=%s', async dirty => {
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    const draft = dirty ? baseConfig.source_text + '# retained intent\n' : baseConfig.source_text
    if (dirty) fireEvent.input(container.querySelector('textarea')!, { target: { value: draft } })
    let finish!: (value: typeof baseConfig) => void
    apiMocks.fetchRuntimeTomlConfig.mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-read-current"]')!)
    await waitFor(() => expect(apiMocks.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(2))
    await act(() => workspace(null))
    await act(() => workspace('/test/A'))
    await act(async () => { finish(baseConfig); await Promise.resolve() })
    await waitFor(() => expect(apiMocks.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(3))
    await waitFor(() => expect(container.textContent).toContain('보관된 초안을 복구했습니다'))
    expect(container.querySelector('textarea')?.value).toBe(draft)
    expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(!dirty)
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
  })

  it('automatically rereads a clean load superseded by an external write', async () => {
    let finish!: (value: typeof baseConfig) => void
    apiMocks.fetchRuntimeTomlConfig.mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(apiMocks.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    const latest = { ...baseConfig, source_text: baseConfig.source_text + '# latest writer\n', source_revision: 'f'.repeat(64) }
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(latest)
    await act(() => announceRuntimeTomlWritten())
    await act(async () => { finish(baseConfig); await Promise.resolve() })
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(latest.source_text))
    expect(apiMocks.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(2)
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
  })

  it('rejects a comparison response superseded by another writer', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    const draft = baseConfig.source_text + '# retained\n'
    fireEvent.input(container.querySelector('textarea')!, { target: { value: draft } })
    let finish!: (value: typeof baseConfig) => void
    apiMocks.fetchRuntimeTomlConfig.mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-read-current"]')!)
    await waitFor(() => expect(apiMocks.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(2))
    await act(() => announceRuntimeTomlWritten())
    await act(async () => { finish(baseConfig); await Promise.resolve() })
    expect(container.querySelector('[data-testid="runtime-toml-adopt-revision"]')).toBeNull()
    expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(true)
    expect(container.querySelector('textarea')?.value).toBe(draft)
    const current = { ...baseConfig, source_revision: 'd'.repeat(64) }
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(current)
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-read-current"]')!)
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-adopt-revision"]')).not.toBeNull())
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-adopt-revision"]')!)
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]')!)
    await waitFor(() => expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledWith(draft, current.source_revision, expect.any(Object)))
  })

  it('blocks a lost typed-patch receipt across remount until comparison adoption', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    apiMocks.patchRuntimeRouting.mockRejectedValueOnce(new Error('receipt lost'))
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(richConfig.source_text))
    fireEvent.change(container.querySelector('[aria-label="default runtime"]')!, { target: { value: 'openai.gpt' } })
    await waitFor(() => expect(container.textContent).toContain('파일 변경 여부를 확인하지 못했습니다'))
    render(null, container)
    render(html`<${RuntimeTomlEditor} />`, container)
    fireEvent.change(container.querySelector('[aria-label="default runtime"]')!, { target: { value: 'openai.gpt' } })
    expect(apiMocks.patchRuntimeRouting).toHaveBeenCalledTimes(1)
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce({ ...richConfig, source_revision: 'e'.repeat(64) })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-read-current"]')!)
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-adopt-revision"]')).not.toBeNull())
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-adopt-revision"]')!)
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-routing"]')!)
    fireEvent.change(container.querySelector('[aria-label="default runtime"]')!, { target: { value: 'openai.gpt' } })
    await waitFor(() => expect(apiMocks.patchRuntimeRouting).toHaveBeenCalledTimes(2))
  })

  it('retains a hidden dirty draft when an external write is announced', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    const draft = baseConfig.source_text + '# hidden local\n'
    fireEvent.input(container.querySelector('textarea')!, { target: { value: draft } })
    render(null, container); announceRuntimeTomlWritten()
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(draft))
    expect(container.textContent).toContain('다른 화면의 설정 변경 요청')
    expect(apiMocks.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(true)
  })

  it('keeps file identity and the draft when a compare read resolves another path', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    const draft = baseConfig.source_text + '# keep this file\n'
    fireEvent.input(container.querySelector('textarea')!, { target: { value: draft } })
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValue({ ...baseConfig, path: '/other/runtime.toml', source_text: '# other file\n' })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-read-current"]')!)
    await waitFor(() => expect(container.textContent).toContain('현재 파일 경로가 편집 중인 runtime.toml과 다릅니다'))
    expect(container.querySelector('textarea')?.value).toBe(draft)
    expect(container.querySelector('[data-testid="runtime-toml-path"]')?.textContent).toContain(MOCK_RUNTIME_PATH)
    expect(container.querySelector('[data-testid="runtime-toml-adopt-revision"]')).toBeNull()
    expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(true)
  })

  it('withdraws the editor without fetching or losing its draft until workspace verification', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    const draft = baseConfig.source_text + '# retained during disconnect\n'
    fireEvent.input(container.querySelector('textarea')!, { target: { value: draft } })
    await act(() => workspace(null))
    expect(container.querySelector('textarea')).toBeNull()
    expect(container.textContent).toContain('보관된 초안은 유지됩니다')
    expect(apiMocks.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    await act(() => workspace('/test/A'))
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(draft))
    await waitFor(() => expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(false))
    expect(container.querySelector('[data-testid="runtime-toml-conflict"]')).toBeNull()
  })

  it('reloads exact projections with the file and ignores an older projection response', async () => {
    let finishOld!: (value: ReturnType<typeof laneSnapshot>) => void
    apiMocks.fetchStandaloneLanes.mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve }))
      .mockResolvedValue(laneSnapshot(['openai.gpt'], []))
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    await waitFor(() => expect(apiMocks.fetchStandaloneLanes).toHaveBeenCalledTimes(1))
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValue({ ...baseConfig, source_revision: 'b'.repeat(64) })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-refresh"]')!)
    await waitFor(() => expect(container.querySelector('[data-testid="exact-lane-librarian_exact"]')?.textContent).toContain('1. openai.gpt'))
    await act(async () => { finishOld(laneSnapshot(['runpod_mtp.qwen'], [])); await Promise.resolve() })
    expect(container.querySelector('[data-testid="exact-lane-librarian_exact"]')?.textContent).toContain('1. openai.gpt')
    expect(container.querySelector('[data-testid="exact-lane-librarian_exact"]')?.textContent).not.toContain('1. runpod_mtp.qwen')
  })

  it('refreshes exact projections after delayed setup resume even after editor remount', async () => {
    let finishResume!: (value: unknown) => void
    let published = false
    vi.mocked(coreApi.postControlPlane).mockImplementationOnce(() => new Promise(resolve => { finishResume = resolve }))
    apiMocks.fetchStandaloneLanes.mockImplementation(async () => laneSnapshot(published ? ['openai.gpt'] : ['runpod_mtp.qwen'], []))
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    fireEvent.input(container.querySelector('textarea')!, { target: { value: baseConfig.source_text + '# setup\n' } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]')!)
    await waitFor(() => expect(coreApi.postControlPlane).toHaveBeenCalledTimes(1))
    render(null, container); render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('[data-testid="exact-lane-librarian_exact"]')?.textContent).toContain('1. runpod_mtp.qwen'))
    published = true
    await act(async () => { finishResume({ runtime_ready: true, exact_output_authority_available: true, model_setup: { status: 'available' } }); await Promise.resolve() })
    await waitFor(() => expect(container.querySelector('[data-testid="exact-lane-librarian_exact"]')?.textContent).toContain('1. openai.gpt'))
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
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent)
      .toContain('saved'))
    expect(container.querySelector('[data-testid="runtime-toml-line-numbers"]')?.textContent).toBe('1\n2\n3')
    expect(container.querySelector('[data-testid="runtime-toml-stats"]')?.textContent).toContain('3 lines')
    expect(container.querySelector('[data-testid="runtime-toml-code-frame"]')?.classList.contains('v2-monitoring-code-frame')).toBe(true)
    expect(container.querySelector('.v2-monitoring-toolbar')).not.toBeNull()
  })

  it('renders a typed Keeper effective-value error instead of a blank value', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce({
      ...baseConfig,
      keeper_settings: [{
        key: 'memory_os.librarian_enabled',
        env: 'MASC_KEEPER_MEMORY_OS_LIBRARIAN',
        configured_value: 'invalid',
        source: 'env',
        effective_value: null,
        effective_error: 'expected a boolean',
        applied_at: null,
        reload_class: 'restart',
        requires_restart: false,
        application_status: 'invalid',
        consumers: ['Keeper_memory_os'],
      }],
    })

    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector(
        '[data-testid="runtime-keeper-setting-error-MASC_KEEPER_MEMORY_OS_LIBRARIAN"]',
      )?.textContent).toContain('expected a boolean')
    })
    expect(container.querySelector('[data-testid="runtime-keeper-setting-matrix"]')?.textContent)
      .toContain('invalid → —')
  })

  it('re-reads runtime.toml when another surface announces a write', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement | null)?.value).toBe(baseConfig.source_text)
    })

    const laneSource = `${baseConfig.source_text}\n[runtime.lanes.coding]\ncandidates = ["runpod_mtp.qwen"]\n`
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce({ ...baseConfig, source_text: laneSource })
    announceRuntimeTomlWritten()

    await waitFor(() => {
      expect(apiMocks.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(2)
      expect((container.querySelector('textarea') as HTMLTextAreaElement | null)?.value).toBe(laneSource)
    })
  })

  it('keeps an unsaved draft when another surface announces a write, and says the file changed', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement | null)?.value).toBe(baseConfig.source_text)
    })
    const draft = `${baseConfig.source_text}\n# draft\n`
    fireEvent.input(container.querySelector('textarea') as HTMLTextAreaElement, { target: { value: draft } })
    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('modified')
    })

    announceRuntimeTomlWritten()

    await waitFor(() => {
      expect(container.textContent).toContain('다른 화면의 설정 변경 요청')
    })
    expect(apiMocks.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toBe(draft)
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
      expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledWith(nextSource, baseConfig.source_revision, expect.objectContaining({ beforeDispatch: expect.any(Function) }))
      expect(container.textContent).toContain('Skill catalog 게시됨')
      expect(container.textContent).toContain('파일 내구성 확인됨')
    })
    expect(saveButton.disabled).toBe(true)
    expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toBe(nextSource)
    expect(container.querySelector('[data-testid="runtime-toml-impact-preview"]')).toBeNull()
    expect(runtimeRefreshMock.refreshRuntimeConfigConsumers).toHaveBeenCalledTimes(1)
  })

  it('renders runtime environment fields as structured projections', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.textContent).toContain('런타임 환경')
      // Capability chips remain observations; the context request is editable
      // through the shared model declaration and existing save path.
      const modelsSection = container.querySelector('[data-testid="runtime-section-models"]')
      expect(modelsSection?.textContent).toContain('qwen')
      expect(modelsSection?.textContent).toContain('128K ctx')
      expect((container.querySelector('[data-testid="runtime-provider-runpod_mtp-transport"]') as HTMLInputElement | null)?.value)
        .toBe('https://runpod.example/v1')
    })

    expect(container.querySelector('[data-testid="runtime-environment-save"]')).toBeNull()
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
  })

  it('edits provider transport and credentials as a draft and applies them through the existing save path', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-providers"]')).not.toBeNull()
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-providers"]') as HTMLButtonElement)

    const transport = container.querySelector('[data-testid="runtime-provider-runpod_mtp-transport"]') as HTMLInputElement
    const credential = container.querySelector('[data-testid="runtime-provider-runpod_mtp-credential"]') as HTMLInputElement

    expect(transport.readOnly).toBe(false)
    expect(transport.disabled).toBe(false)
    expect(transport.value).toBe('https://runpod.example/v1')
    expect(credential.value).toBe('RUNPOD_API_KEY')

    fireEvent.input(transport, { target: { value: 'https://runpod.example/v2' } })
    fireEvent.input(credential, { target: { value: 'RUNPOD_API_KEY_NEXT' } })

    await waitFor(() => {
      const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
      expect(source).toContain('endpoint = "https://runpod.example/v2"')
      expect(source).toContain('key = "RUNPOD_API_KEY_NEXT"')
      expect(source).not.toContain('endpoint = "https://runpod.example/v1"')
      expect(source).not.toContain('key = "RUNPOD_API_KEY"')
      expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('modified')
      expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(false)
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)

    await waitFor(() => {
      const savedSource = apiMocks.saveRuntimeTomlConfig.mock.calls[0]?.[0] as string
      expect(savedSource).toContain('endpoint = "https://runpod.example/v2"')
      expect(savedSource).toContain('key = "RUNPOD_API_KEY_NEXT"')
      expect(container.textContent).toContain('적용됨')
    })
    expect(apiMocks.patchRuntimeRouting).not.toHaveBeenCalled()
    expect(apiMocks.patchRuntimeAssignment).not.toHaveBeenCalled()
  })

  it('disables providers and individual bindings through typed draft controls', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-providers"]')).not.toBeNull()
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-providers"]') as HTMLButtonElement)
    fireEvent.click(
      container.querySelector('[data-testid="runtime-provider-runpod_mtp-enabled"]') as HTMLInputElement,
    )
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-bindings"]') as HTMLButtonElement)
    fireEvent.click(
      container.querySelector('[data-testid="runtime-binding-runpod_mtp.qwen-enabled"]') as HTMLInputElement,
    )

    await waitFor(() => {
      const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
      expect(source.match(/^enabled = false$/gm)).toHaveLength(2)
      expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('modified')
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)

    await waitFor(() => {
      const savedSource = apiMocks.saveRuntimeTomlConfig.mock.calls[0]?.[0] as string
      expect(savedSource.match(/^enabled = false$/gm)).toHaveLength(2)
    })
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

  it('prevents raw edits during a typed patch from reverting the accepted routing', async () => {
    let finish!: (value: ReturnType<typeof committedRuntimeTomlConfigFixture>) => void
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    apiMocks.patchRuntimeRouting.mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(richConfig.source_text))
    fireEvent.change(container.querySelector('[aria-label="default runtime"]')!, { target: { value: 'openai.gpt' } })
    await waitFor(() => expect(apiMocks.patchRuntimeRouting).toHaveBeenCalledTimes(1))
    expect(container.querySelector('textarea')?.disabled).toBe(true)
    // A queued input handler from before the disabled render must also refuse it.
    fireEvent.input(container.querySelector('textarea')!, { target: { value: richConfig.source_text + '# during patch\n' } })
    const patched = richConfig.source_text.replace('default = "runpod_mtp.qwen"', 'default = "openai.gpt"')
    await act(async () => { finish(committedRuntimeTomlConfigFixture({ ...richConfig, source_text: patched })); await Promise.resolve() })
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(patched))
    const next = patched + '# after patch\n'
    fireEvent.input(container.querySelector('textarea')!, { target: { value: next } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]')!)
    await waitFor(() => expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledWith(next, expect.any(String), expect.any(Object)))
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
      expect(apiMocks.patchRuntimeRouting).toHaveBeenCalledWith('default', 'openai.gpt', expect.objectContaining({ beforeDispatch: expect.any(Function) }))
      expect((container.querySelector('textarea') as HTMLTextAreaElement).value).toContain('default = "openai.gpt"')
    })
    expect(coreApi.postControlPlane).toHaveBeenCalledWith('/api/v1/runtime/setup/resume', {}, undefined, expect.objectContaining({ signal: expect.any(AbortSignal) }))
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('saved'))
    expect(runtimeRefreshMock.refreshRuntimeConfigConsumers).toHaveBeenCalledTimes(1)
  })

  it('updates the assignment select after patching a keeper runtime', async () => {
    keepers.value = [{ name: 'sangsu', status: 'idle' }]
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-assignments"]')).not.toBeNull()
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-assignments"]') as HTMLButtonElement)

    const select = container.querySelector('[aria-label="sangsu 런타임 배정"]') as HTMLSelectElement
    expect(select.value).toBe('runpod_mtp.qwen')

    fireEvent.change(select, { target: { value: 'openai.gpt' } })

    await waitFor(() => {
      expect(apiMocks.patchRuntimeAssignment).toHaveBeenCalledWith(
        'sangsu',
        'openai.gpt',
        {
          state: 'runtime_config_present',
          source_revision: baseConfig.source_revision,
          assignment: { state: 'missing' },
        },
        expect.objectContaining({ beforeDispatch: expect.any(Function) }),
      )
    })

    await waitFor(() => {
      expect((container.querySelector('[aria-label="sangsu 런타임 배정"]') as HTMLSelectElement).value)
        .toBe('openai.gpt')
    })
    expect(container.querySelector('[data-testid="runtime-assignments-group-pinned"]')?.textContent)
      .toContain('sangsu')
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent)
      .toContain('saved'))
  })

  it('notifies onSaved after a successful save so parent surfaces can refresh', async () => {
    const onSaved = vi.fn()
    render(html`<${RuntimeTomlEditor} onSaved=${onSaved} />`, container)

    await waitFor(() => {
      expect((container.querySelector('textarea') as HTMLTextAreaElement | null)?.value).toBe(baseConfig.source_text)
    })

    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: `${baseConfig.source_text}\n[runtime.assignments]\nsangsu = "runpod_mtp.qwen"\n` } })

    await waitFor(() => {
      expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(false)
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalled()
      expect(onSaved).toHaveBeenCalledTimes(1)
    })
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
      expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledWith(nextSource, baseConfig.source_revision, expect.objectContaining({ beforeDispatch: expect.any(Function) }))
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

  it('renders Runtime Lane editing in the section nav', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-routing"]')).not.toBeNull()
    })

    const nav = container.querySelector('nav.rt-nav') as HTMLElement
    expect(nav.getAttribute('aria-label')).toBe('런타임 편집기 섹션')

    const expected: Array<[string, string]> = [
      ['routing', '라우팅'],
      ['lanes', 'Lane 후보'],
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

  it('moves a declared Librarian slot through routing and saves its provider deadline separately', async () => {
    const laneSource = `${richSourceText.replaceAll('providers.runpod_mtp', 'providers . "runpod_mtp"')}\n[providers.codex_subscription]\nprotocol = "codex-app-server"\ncommand = "codex"\n\n[models.luna]\napi-name = "gpt-6-luna"\nmax-context = 272000\n\n[codex_subscription.luna]\n\n[runtime.exact_output_lanes.librarian_exact]\nslots = ["runpod_mtp.qwen", "openai.gpt"]\ncli_slots = ["codex_subscription.luna"]\n`
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce({ ...baseConfig, source_text: laneSource })
    apiMocks.fetchStandaloneLanes.mockResolvedValueOnce(laneSnapshot())
      .mockResolvedValue(laneSnapshot(['openai.gpt', 'runpod_mtp.qwen']))
    apiMocks.patchRuntimeExactSlot.mockResolvedValueOnce(committedRuntimeTomlConfigFixture({
      ...baseConfig, source_text: laneSource,
    }))
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-nav-lanes"]')).not.toBeNull())
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-lanes"]') as HTMLButtonElement)
    await waitFor(() => expect(container.querySelector('[data-testid="exact-lane-librarian_exact"]')).not.toBeNull())
    expect(container.textContent).toContain('missing_deadline')
    fireEvent.click(container.querySelector('[aria-label="openai.gpt 위로"]') as HTMLButtonElement)
    await waitFor(() => expect(apiMocks.patchRuntimeExactSlot)
      .toHaveBeenCalledWith('librarian_exact', 'move', 'openai.gpt', 'up', expect.objectContaining({ beforeDispatch: expect.any(Function) })))
    await waitFor(() => expect((container.querySelector('[aria-label="openai.gpt 위로"]') as HTMLButtonElement).disabled).toBe(true))
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent)
      .toContain('saved'))
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    fireEvent.change(container.querySelector('[aria-label="runpod_mtp exact-body-timeout-s"]') as HTMLInputElement,
      { target: { value: '1200' } })
    await waitFor(() => expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled)
      .toBe(false))
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)
    await waitFor(() => expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalled())
    const saved = apiMocks.saveRuntimeTomlConfig.mock.calls[0]?.[0] as string
    expect(saved).toContain('slots = ["runpod_mtp.qwen", "openai.gpt"]')
    expect(saved).not.toContain('[providers.runpod_mtp]')
    expect(getRuntimeTomlKey(saved, 'providers.runpod_mtp', 'exact-body-timeout-s')).toBe('1200')
  })

  it('keeps malformed raw drafts visible and disables structured edits until repaired', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect((container.querySelector('textarea') as HTMLTextAreaElement)?.value).toBe(richSourceText))
    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    const malformed = `${richSourceText}\n[providers.\n`
    fireEvent.input(textarea, { target: { value: malformed } })
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-parse-error"]')?.textContent).toContain('TOML'))
    expect(textarea.value).toBe(malformed)
    expect(container.querySelector('[data-testid="runtime-toml-impact-preview"]')).toBeNull()
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-providers"]') as HTMLButtonElement)
    const controls = Array.from(container.querySelectorAll('[data-testid="runtime-toml-structured"] input, [data-testid="runtime-toml-structured"] select'))
    expect(controls.length).toBeGreaterThan(0)
    expect(controls.every(control => (control as HTMLInputElement).disabled)).toBe(true)
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    expect(apiMocks.patchRuntimeRouting).not.toHaveBeenCalled()
    fireEvent.input(textarea, { target: { value: richSourceText } })
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-parse-error"]')).toBeNull())
  })

  it('sends a new runtime to server classification and shows a lane rejection', async () => {
    apiMocks.fetchRuntimeResolved.mockResolvedValueOnce({ runtimes: [
      { id: 'next.client', provider: 'next' },
    ] })
    apiMocks.patchRuntimeExactSlot.mockRejectedValueOnce(new Error('CLI tail is not supported'))
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-nav-lanes"]')).not.toBeNull())
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-lanes"]') as HTMLButtonElement)
    await waitFor(() => expect(container.querySelector('[aria-label="workspace_curator_exact 추가할 runtime"]')).not.toBeNull())
    const select = container.querySelector('[aria-label="workspace_curator_exact 추가할 runtime"]') as HTMLSelectElement
    fireEvent.change(select, { target: { value: 'next.client' } })
    fireEvent.click(container.querySelector('[data-testid="exact-lane-workspace_curator_exact"] button[aria-label="workspace_curator_exact 후보 추가"]') as HTMLButtonElement)
    await waitFor(() => expect(apiMocks.patchRuntimeExactSlot)
      .toHaveBeenCalledWith('workspace_curator_exact', 'append', 'next.client', undefined, expect.objectContaining({ beforeDispatch: expect.any(Function) })))
    expect(container.textContent).toContain('CLI tail is not supported')
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
  })

  it('configures Candle appraisal through the exact-lane slot endpoint', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-nav-lanes"]')).not.toBeNull())
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-lanes"]') as HTMLButtonElement)
    await waitFor(() => expect(container.querySelector(
      '[aria-label="candle_appraiser 추가할 runtime"]')).not.toBeNull())
    const select = container.querySelector(
      '[aria-label="candle_appraiser 추가할 runtime"]') as HTMLSelectElement
    fireEvent.change(select, { target: { value: 'openai.gpt' } })
    fireEvent.click(container.querySelector('[data-testid="exact-lane-candle_appraiser"] button[aria-label="candle_appraiser 후보 추가"]') as HTMLButtonElement)
    await waitFor(() => expect(apiMocks.patchRuntimeExactSlot)
      .toHaveBeenCalledWith('candle_appraiser', 'append', 'openai.gpt', undefined, expect.objectContaining({ beforeDispatch: expect.any(Function) })))
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
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

  it('does not close overlay mode when interacting with editor controls', async () => {
    const onClose = vi.fn()
    render(html`<${RuntimeTomlEditor} onClose=${onClose} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-models"]')).not.toBeNull()
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-models"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-section-title"]')?.textContent).toBe('모델')
    })
    expect(onClose).not.toHaveBeenCalled()

    fireEvent.click(container.querySelector('.rt-overlay') as HTMLElement)

    expect(onClose).toHaveBeenCalledTimes(1)
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
      expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledWith(nextSource, baseConfig.source_revision, expect.objectContaining({ beforeDispatch: expect.any(Function) }))
    })
    expect((container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value).toBe(nextSource)
  })

  it('preserves a conflicted draft and only retries against an explicitly adopted revision', async () => {
    const current = { source_path: MOCK_RUNTIME_PATH, source_revision: 'b'.repeat(64),
      source_text: `${baseConfig.source_text}# another writer\n` }
    apiMocks.saveRuntimeTomlConfig.mockRejectedValueOnce(new RuntimeTomlRevisionConflict('File changed', current))
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    const draft = `${baseConfig.source_text}# my unsaved change\n`
    fireEvent.input(container.querySelector('textarea')!, { target: { value: draft } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]')!)
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-conflict"]')).not.toBeNull())
    expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledWith(draft, baseConfig.source_revision, expect.objectContaining({ beforeDispatch: expect.any(Function) }))
    expect(container.querySelector('textarea')?.value).toBe(draft)
    expect(container.querySelector('[aria-label="현재 서버 원문"]')?.textContent).toBe(current.source_text)
    expect(container.querySelector('[aria-label="편집 기준 원문"]')?.textContent).toBe(baseConfig.source_text)
    expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(true)
    fireEvent.keyDown(container.querySelector('textarea')!, { key: 's', ctrlKey: true })
    expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-adopt-revision"]')!)
    expect(container.querySelector('textarea')?.value).toBe(draft)
    expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]')!)
    await waitFor(() => expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenLastCalledWith(draft, current.source_revision, expect.objectContaining({ beforeDispatch: expect.any(Function) })))
  })

  it('replaces the draft with the displayed current file only on the separate replace action', async () => {
    const current = { source_path: MOCK_RUNTIME_PATH, source_revision: 'b'.repeat(64),
      source_text: `${baseConfig.source_text}# server text\n` }
    apiMocks.saveRuntimeTomlConfig.mockRejectedValueOnce(new RuntimeTomlRevisionConflict('File changed', current))
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    fireEvent.input(container.querySelector('textarea')!, { target: { value: `${baseConfig.source_text}# draft\n` } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]')!)
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-replace-draft"]')).not.toBeNull())
    const initialLaneReads = apiMocks.fetchStandaloneLanes.mock.calls.length
    let finishLaneRead!: (value: ReturnType<typeof laneSnapshot>) => void
    const heldLaneRead = new Promise<ReturnType<typeof laneSnapshot>>(resolve => { finishLaneRead = resolve })
    apiMocks.fetchStandaloneLanes.mockReturnValueOnce(heldLaneRead)
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-replace-draft"]')!)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(current.source_text))
    await waitFor(() => expect(apiMocks.fetchStandaloneLanes).toHaveBeenCalledTimes(initialLaneReads + 1))
    // The session adopts immediately; its new config identity withdraws the old
    // projection while the replacement reading is still pending.
    expect(container.querySelector('[data-testid="runtime-toml-conflict"]')).toBeNull()
    expect(container.querySelector('[data-testid="runtime-exact-lane-editor"]')).toBeNull()
    expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(true)
    finishLaneRead(laneSnapshot(['openai.gpt'], []))
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-exact-lane-editor"]')).not.toBeNull())
    expect(container.querySelector('[data-testid="exact-lane-librarian_exact"]')?.textContent).toContain('1. openai.gpt')
    expect(container.querySelector('[data-testid="exact-lane-librarian_exact"]')?.textContent).not.toContain('1. runpod_mtp.qwen')
    expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(true)
    expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    const amended = `${current.source_text}# after explicit replace\n`
    fireEvent.input(container.querySelector('textarea')!, { target: { value: amended } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]')!)
    await waitFor(() => expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenLastCalledWith(amended, current.source_revision, expect.objectContaining({ beforeDispatch: expect.any(Function) })))
  })

  it('reads current text for comparison without replacing a dirty draft or its save basis', async () => {
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    const draft = `${baseConfig.source_text}# local\n`
    fireEvent.input(container.querySelector('textarea')!, { target: { value: draft } })
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce({ ...baseConfig,
      source_text: `${baseConfig.source_text}# latest\n`, source_revision: 'c'.repeat(64) })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-read-current"]')!)
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-conflict"]')).not.toBeNull())
    expect(container.querySelector('textarea')?.value).toBe(draft)
    expect(container.querySelector('[aria-label="편집 기준 원문"]')?.textContent).toBe(baseConfig.source_text)
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(true)
  })

  it('keeps draft and revision after an unknown save result and explains file uncertainty', async () => {
    apiMocks.saveRuntimeTomlConfig.mockRejectedValueOnce(new Error('connection lost'))
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
    const draft = `${baseConfig.source_text}# local\n`
    fireEvent.input(container.querySelector('textarea')!, { target: { value: draft } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]')!)
    await waitFor(() => expect(container.textContent).toContain('파일 변경 여부를 확인하지 못했습니다'))
    expect(container.querySelector('textarea')?.value).toBe(draft)
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]')!)
    expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(true)
  })

  it('allows correcting and retrying an actual raw-save validation refusal without adopting a file', async () => {
    vi.spyOn(devToken, 'ensureDevToken').mockResolvedValue(undefined)
    apiMocks.saveRuntimeTomlConfig.mockImplementation(actualSaveRuntimeTomlConfig)
    const fetchMock = vi.fn().mockResolvedValueOnce(new Response(JSON.stringify({
      error: 'runtime config parse failed: invalid fixture declaration',
    }), { status: 400, headers: { 'Content-Type': 'application/json' } }))
      .mockImplementation(async (_path: string, init: RequestInit) => {
        const request = JSON.parse(init.body as string) as { source_text: string }
        const receipt = committedRuntimeTomlConfigFixture({ ...baseConfig, source_text: request.source_text })
        receipt.source_revision = 'b'.repeat(64); receipt.commit.source_revision = receipt.source_revision
        receipt.application.skills = { state: 'published', input_source_revision: receipt.source_revision,
          snapshot_revision: 'skill-snapshot', catalog_revision: 'skill-catalog', config_state: 'configured' }
        return new Response(JSON.stringify(receipt), { status: 200, headers: { 'Content-Type': 'application/json' } })
      })
    vi.stubGlobal('fetch', fetchMock)
    try {
      render(html`<${RuntimeTomlEditor} />`, container)
      await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(baseConfig.source_text))
      const draft = baseConfig.source_text + '# rejected declaration\n'
      const textarea = container.querySelector('textarea')!, save = container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement
      fireEvent.input(textarea, { target: { value: draft } }); fireEvent.click(save)
      await waitFor(() => expect(container.textContent).toContain('invalid fixture declaration'))
      expect(textarea.value).toBe(draft)
      expect(save.disabled).toBe(false)
      expect(apiMocks.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(1)
      expect(coreApi.postControlPlane).not.toHaveBeenCalled()
      const corrected = baseConfig.source_text + '# corrected declaration\n'
      fireEvent.input(textarea, { target: { value: corrected } }); fireEvent.click(save)
      await waitFor(() => expect(coreApi.postControlPlane).toHaveBeenCalledTimes(1))
      expect(fetchMock).toHaveBeenCalledTimes(2)
      expect(JSON.parse(fetchMock.mock.calls[1]![1].body as string)).toEqual({ source_text: corrected, expected_source_revision: baseConfig.source_revision, expected_source_path: baseConfig.path })
      expect(apiMocks.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    } finally { vi.unstubAllGlobals() }
  })

  it('keeps a prose-only save failure uncertain instead of inferring rejection from its message', async () => {
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
    expect(saveButton.disabled).toBe(true)
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
    // Form-validation errors need role="alert" so screen readers announce them
    // immediately -- they appear without any focus change or navigation.
    expect(container.querySelector('[data-testid="runtime-add-provider-error"]')?.getAttribute('role')).toBe('alert')
    expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).not.toContain('modified')
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
  })

  it('trims a whitespace-only display name to fall back to the id, and trims credential padding', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-providers"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-providers"]') as HTMLButtonElement)
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-toggle"]') as HTMLButtonElement)

    fireEvent.input(container.querySelector('[data-testid="runtime-add-provider-id"]') as HTMLInputElement, {
      target: { value: 'brandnew2' },
    })
    fireEvent.input(container.querySelector('[aria-label="새 provider 표시 이름"]') as HTMLInputElement, {
      target: { value: '   ' },
    })
    fireEvent.input(container.querySelector('[aria-label="새 provider transport 값"]') as HTMLInputElement, {
      target: { value: 'https://brandnew2.example/v1' },
    })
    fireEvent.input(container.querySelector('[aria-label="새 provider credential 값"]') as HTMLInputElement, {
      target: { value: '  BRANDNEW2_KEY  ' },
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-submit"]') as HTMLButtonElement)

    await waitFor(() => {
      const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
      expect(source).toContain('display-name = "brandnew2"')
      expect(source).toContain('key = "BRANDNEW2_KEY"')
      expect(source).not.toContain('display-name = "   "')
      expect(source).not.toContain('key = "  BRANDNEW2_KEY  "')
    })
  })

  it('deletes a provider alias as a draft and retargets the default runtime to a remaining binding', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-providers"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-providers"]') as HTMLButtonElement)
    fireEvent.click(container.querySelector('[data-testid="runtime-provider-runpod_mtp-delete"]') as HTMLButtonElement)

    await waitFor(() => {
      const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
      expect(source).toContain('default = "openai.gpt"')
      expect(source).not.toContain('[providers.runpod_mtp]')
      expect(source).not.toContain('[providers.runpod_mtp.credentials]')
      expect(source).not.toContain('[runpod_mtp.qwen]')
      expect(source).toContain('[providers.openai]')
      expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('modified')
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)
    await waitFor(() => {
      const savedSource = apiMocks.saveRuntimeTomlConfig.mock.calls[0]?.[0] as string
      expect(savedSource).toContain('default = "openai.gpt"')
      expect(savedSource).not.toContain('[providers.runpod_mtp]')
    })
  })

  it('blocks deleting the final runtime-bearing provider alias from the structured view', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce({
      ...baseConfig,
      source_text: `${richSourceText
        .replace(/\n\[providers\.openai\][\s\S]*?\n\[models\.qwen\]/, '\n[models.qwen]')
        .replace(/\n\[models\.gpt\][\s\S]*?\n\[runpod_mtp\.qwen\]/, '\n[runpod_mtp.qwen]')
        .replace(/\n\[openai\.gpt\][\s\S]*$/m, '\n')}`,
    })
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-providers"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-providers"]') as HTMLButtonElement)
    fireEvent.click(container.querySelector('[data-testid="runtime-provider-runpod_mtp-delete"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-delete-provider-error"]')?.textContent)
        .toContain('마지막 runtime binding')
    })
    expect(container.querySelector('[data-testid="runtime-delete-provider-error"]')?.getAttribute('role')).toBe('alert')
    expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).not.toContain('modified')
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
  })

  it('offers backend-validated HTTP protocols plus the typed Codex official client', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-providers"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-providers"]') as HTMLButtonElement)
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-toggle"]') as HTMLButtonElement)

    const protocolOptions = Array.from(
      container.querySelectorAll('[aria-label="새 provider protocol"] option'),
    ).map(option => (option as HTMLOptionElement).value)
    expect(protocolOptions).toEqual([
      'messages-http',
      'openai-compatible-http',
      'ollama-http',
      'codex-app-server',
      'claude-code',
      'antigravity-cli',
      'muse-serve',
    ])
    expect(protocolOptions).not.toContain('messages-cli')
    expect(protocolOptions).not.toContain('openai-compatible-cli')
    // No transport-kind selector left to switch to 'command'.
    expect(container.querySelector('[aria-label="새 provider transport 종류"]')).toBeNull()
  })

  it('creates a Codex subscription provider and binding with the enforced no-key boundary', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-providers"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-providers"]') as HTMLButtonElement)
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-toggle"]') as HTMLButtonElement)
    fireEvent.input(container.querySelector('[data-testid="runtime-add-provider-id"]') as HTMLInputElement, {
      target: { value: 'codex_subscription' },
    })
    fireEvent.change(container.querySelector('[aria-label="새 provider protocol"]') as HTMLSelectElement, {
      target: { value: 'codex-app-server' },
    })

    const credentialType = container.querySelector('[aria-label="새 provider credential 종류"]') as HTMLSelectElement
    expect(credentialType.value).toBe('none')
    expect(credentialType.disabled).toBe(true)
    expect(container.querySelector('[aria-label="새 provider credential 값"]')).toBeNull()

    fireEvent.input(container.querySelector('[aria-label="새 provider transport 값"]') as HTMLInputElement, {
      target: { value: '/Users/dancer/.local/bin/codex' },
    })
    fireEvent.input(container.querySelector('[data-testid="runtime-add-provider-account-home"]') as HTMLInputElement, {
      target: { value: '/tmp/codex-second' },
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-submit"]') as HTMLButtonElement)

    await waitFor(() => {
      const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
      expect(source).toContain('[providers.codex_subscription]')
      expect(source).toContain('protocol = "codex-app-server"')
      expect(source).toContain('command = "/Users/dancer/.local/bin/codex"')
      expect(source).toContain('account-home = "/tmp/codex-second"')
      expect(source).toContain('is-non-interactive = true')
      expect(source).not.toContain('[providers.codex_subscription.credentials]')
    })

    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-bindings"]') as HTMLButtonElement)
    fireEvent.change(container.querySelector('[data-testid="runtime-add-binding-provider"]') as HTMLSelectElement, {
      target: { value: 'codex_subscription' },
    })
    fireEvent.change(container.querySelector('[data-testid="runtime-add-binding-model"]') as HTMLSelectElement, {
      target: { value: 'qwen' },
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-binding-submit"]') as HTMLButtonElement)

    await waitFor(() => {
      const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
      expect(source).toContain('[codex_subscription.qwen]')
      expect(container.querySelector('[data-testid="runtime-add-binding-error"]')).toBeNull()
    })
  })

  it('requires and persists an explicit Muse account home without an API key', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-providers"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-providers"]') as HTMLButtonElement)
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-toggle"]') as HTMLButtonElement)
    fireEvent.input(container.querySelector('[data-testid="runtime-add-provider-id"]') as HTMLInputElement,
      { target: { value: 'selected_muse' } })
    fireEvent.change(container.querySelector('[aria-label="새 provider protocol"]') as HTMLSelectElement,
      { target: { value: 'muse-serve' } })
    fireEvent.input(container.querySelector('[aria-label="새 provider transport 값"]') as HTMLInputElement,
      { target: { value: '/synthetic/bin/muse' } })
    const credential = container.querySelector('[aria-label="새 provider credential 종류"]') as HTMLSelectElement
    expect(credential.value).toBe('none')
    expect(credential.disabled).toBe(true)
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-submit"]') as HTMLButtonElement)
    expect(container.textContent).toContain('사용할 계정 홈을 선택하세요')
    fireEvent.input(container.querySelector('[data-testid="runtime-add-provider-account-home"]') as HTMLInputElement,
      { target: { value: '/synthetic/accounts/muse-one' } })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-submit"]') as HTMLButtonElement)
    await waitFor(() => {
      const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
      expect(source).toContain('[providers.selected_muse]')
      expect(source).toContain('protocol = "muse-serve"')
      expect(source).toContain('account-home = "/synthetic/accounts/muse-one"')
      expect(source).not.toContain('[providers.selected_muse.credentials]')
    })
  })

  it('materializes every required Antigravity provider field', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-providers"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-providers"]') as HTMLButtonElement)
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-toggle"]') as HTMLButtonElement)
    fireEvent.input(container.querySelector('[data-testid="runtime-add-provider-id"]') as HTMLInputElement, {
      target: { value: 'antigravity_subscription' },
    })
    fireEvent.change(container.querySelector('[aria-label="새 provider protocol"]') as HTMLSelectElement, {
      target: { value: 'antigravity-cli' },
    })

    const credentialType = container.querySelector('[aria-label="새 provider credential 종류"]') as HTMLSelectElement
    expect(credentialType.value).toBe('file')
    expect(credentialType.disabled).toBe(true)
    fireEvent.input(container.querySelector('[aria-label="새 provider transport 값"]') as HTMLInputElement, {
      target: { value: '/opt/homebrew/bin/antigravity' },
    })
    fireEvent.input(container.querySelector('[aria-label="새 provider credential 값"]') as HTMLInputElement, {
      target: { value: '/Users/dancer/.config/antigravity/oauth.json' },
    })
    fireEvent.input(container.querySelector('[aria-label="새 Antigravity agent"]') as HTMLInputElement, {
      target: { value: 'gemini-3.1-pro' },
    })
    fireEvent.change(container.querySelector('[aria-label="새 Antigravity effort"]') as HTMLSelectElement, {
      target: { value: 'high' },
    })
    fireEvent.input(container.querySelector('[aria-label="새 Antigravity timeout-s"]') as HTMLInputElement, {
      target: { value: '900' },
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-submit"]') as HTMLButtonElement)

    await waitFor(() => {
      const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
      expect(source).toContain('[providers.antigravity_subscription]')
      expect(source).toContain('protocol = "antigravity-cli"')
      expect(source).toContain('command = "/opt/homebrew/bin/antigravity"')
      expect(source).toContain('agent = "gemini-3.1-pro"')
      expect(source).toContain('effort = "high"')
      expect(source).toContain('timeout-s = 900')
      expect(source).toContain('[providers.antigravity_subscription.credentials]')
      expect(source).toContain('type = "file"')
      expect(source).toContain('path = "/Users/dancer/.config/antigravity/oauth.json"')
    })
  })

  it.each(['wire_capture', 'board'])('refuses server-reserved provider id %s', async reservedId => {
    // The form reads the response's list and keeps no copy of its own.
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce({ ...richConfig, reserved_provider_ids: [reservedId] })
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-providers"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-providers"]') as HTMLButtonElement)
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-toggle"]') as HTMLButtonElement)

    fireEvent.input(container.querySelector('[data-testid="runtime-add-provider-id"]') as HTMLInputElement, {
      target: { value: reservedId },
    })
    fireEvent.input(container.querySelector('[aria-label="새 provider transport 값"]') as HTMLInputElement, {
      target: { value: 'https://irrelevant.example/v1' },
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-provider-submit"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-add-provider-error"]')?.textContent)
        .toContain('예약된 이름')
    })
    expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).not.toContain('modified')
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
  })

  it.each([['500K', 500000], ['1M', 1000000]] as const)(
    'edits existing model context to %s through the existing save path', async (label, tokens) => {
      apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
      render(html`<${RuntimeTomlEditor} />`, container)
      await waitFor(() => expect(container.querySelector('[aria-label="qwen max-context"]')).not.toBeNull())
      fireEvent.click(container.querySelector(`[aria-label="qwen 컨텍스트 ${label}"]`) as HTMLButtonElement)
      await waitFor(() => {
        const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
        expect(source).toContain(`max-context = ${tokens}`)
        expect(source).toContain('api-name = "qwen"')
        expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
      })
      fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)
      await waitFor(() => expect(apiMocks.saveRuntimeTomlConfig.mock.calls[0]?.[0]).toContain(`max-context = ${tokens}`))
    },
  )

  it('saves a typed context after a preset without a separate apply step', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('[aria-label="qwen max-context"]')).not.toBeNull())
    fireEvent.click(container.querySelector('[aria-label="qwen 컨텍스트 500K"]') as HTMLButtonElement)
    fireEvent.input(container.querySelector('[aria-label="qwen max-context"]') as HTMLInputElement, { target: { value: '1000000' } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)
    await waitFor(() => expect(apiMocks.saveRuntimeTomlConfig.mock.calls[0]?.[0]).toContain('max-context = 1000000'))
  })

  it('keeps invalid context drafts across tabs and remount, blocks save, and discards them on reset', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('[aria-label="qwen max-context"]')).not.toBeNull())
    fireEvent.click(container.querySelector('[aria-label="qwen 컨텍스트 500K"]') as HTMLButtonElement)
    fireEvent.input(container.querySelector('[aria-label="qwen max-context"]') as HTMLInputElement, { target: { value: 'invalid' } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-toml"]') as HTMLButtonElement)
    expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(true)
    expect(container.textContent).toContain('unsaved')
    render(null, container); render(html`<${RuntimeTomlEditor} />`, container)
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-models"]') as HTMLButtonElement)
    expect((container.querySelector('[aria-label="qwen max-context"]') as HTMLInputElement).value).toBe('invalid')
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-reset"]') as HTMLButtonElement)
    await waitFor(() => expect((container.querySelector('[aria-label="qwen max-context"]') as HTMLInputElement).value).toBe('128000'))
    expect(container.textContent).not.toContain('컨텍스트는 1 이상의 정수')
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
  })

  it('drops a hidden invalid context draft when raw TOML renames its model', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('[aria-label="qwen max-context"]')).not.toBeNull())
    fireEvent.input(container.querySelector('[aria-label="qwen max-context"]') as HTMLInputElement,
      { target: { value: 'invalid' } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-toml"]') as HTMLButtonElement)
    const source = container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement
    const renamed = source.value.replaceAll('qwen', 'renamed-model') + '\n# retained raw edit\n'
    fireEvent.input(source, { target: { value: renamed } })
    await waitFor(() => expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(false))
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)
    await waitFor(() => expect(apiMocks.saveRuntimeTomlConfig.mock.calls[0]?.[0]).toBe(renamed))
  })

  it('rejects invalid context drafts without changing saved model configuration', async () => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(richConfig)
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('[aria-label="qwen max-context"]')).not.toBeNull())
    for (const value of ['', '0', '-1', '1.5', '9007199254740992']) {
      fireEvent.input(container.querySelector('[aria-label="qwen max-context"]') as HTMLInputElement, { target: { value } })
      await waitFor(() => expect(container.textContent).toContain('컨텍스트는 1 이상의 정수'))
      expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
      expect((container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement).disabled).toBe(true)
    }
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
    fireEvent.input(container.querySelector('[data-testid="runtime-add-model-max-prompt-bytes"]') as HTMLInputElement, { target: { value: '45678' } })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-model-submit"]') as HTMLButtonElement)

    await waitFor(() => {
      const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
      expect(source).toContain('[models.brandnewmodel]')
      expect(source).toContain('max-context = 50000')
      expect(source).toContain('max-prompt-bytes = 45678')
    })
  })

  it('adds a model whose id is on the reserved provider list', async () => {
    // Only a provider id becomes a top-level table. A model id sits under
    // [models], so the list does not apply to it.
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce({ ...richConfig, reserved_provider_ids: ['turn'] })
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-models"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-models"]') as HTMLButtonElement)
    fireEvent.click(container.querySelector('[data-testid="runtime-add-model-toggle"]') as HTMLButtonElement)

    fireEvent.input(container.querySelector('[data-testid="runtime-add-model-id"]') as HTMLInputElement, {
      target: { value: 'turn' },
    })
    fireEvent.input(container.querySelector('[data-testid="runtime-add-model-max-context"]') as HTMLInputElement, {
      target: { value: '50000' },
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-model-submit"]') as HTMLButtonElement)

    await waitFor(() => {
      const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
      expect(source).toContain('[models.turn]')
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

  it('saves unrelated edits with a dormant Muse provider and requires its account home when enabled', async () => {
    const source = `${richConfig.source_text}
[providers.muse_fixture]
protocol = "muse-serve"
command = "muse"
enabled = false
is-non-interactive = true
`
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce({ ...richConfig, source_text: source })
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('textarea')?.value).toBe(source))
    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    const save = container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement
    const edited = `${source}\n# An unrelated operator note\n`
    fireEvent.input(textarea, { target: { value: edited } })
    fireEvent.click(save)
    await waitFor(() => {
      expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledOnce()
      expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledWith(edited, baseConfig.source_revision, expect.objectContaining({ beforeDispatch: expect.any(Function) }))
      expect(container.querySelector('[data-testid="runtime-toml-status"]')?.textContent).toContain('saved')
    })

    fireEvent.input(textarea, { target: { value: edited.replace('enabled = false', 'enabled = true') } })
    fireEvent.click(save)
    await waitFor(() => expect(container.textContent).toContain('사용할 계정 홈을 선택하세요'))
    expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
  })

  it.each(['', '   ', 'relative/account'])('refuses an invalid existing Muse account home before saving (%j)', async home => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce({ ...richConfig,
      source_text: `${richConfig.source_text}
[providers.muse_fixture]
protocol = "muse-serve"
command = "muse"
account-home = "/synthetic/muse"
is-non-interactive = true
` })
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-nav-providers"]')).not.toBeNull())
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-providers"]') as HTMLButtonElement)
    const account = container.querySelector('[data-testid="runtime-provider-muse_fixture-account-home"]') as HTMLInputElement
    expect(account.required).toBe(true)
    expect(account.placeholder).not.toContain('비우면 기본 로그인')
    fireEvent.input(account, { target: { value: home } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)
    await waitFor(() => expect(container.textContent).toContain(home.trim() === ''
      ? '사용할 계정 홈을 선택하세요' : '계정 홈은 절대 경로여야 합니다'))
    expect(apiMocks.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    fireEvent.input(account, { target: { value: '/synthetic/another' } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)
    await waitFor(() => expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledOnce())
    expect(apiMocks.saveRuntimeTomlConfig.mock.calls[0]?.[0]).toContain('account-home = "/synthetic/another"')
  })

  it.each(['claude-code', 'codex-app-server'])('keeps default-account edits available for %s', async protocol => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce({ ...richConfig,
      source_text: `${richConfig.source_text}
[providers.native_fixture]
protocol = "${protocol}"
command = "native-fixture"
account-home = "/synthetic/native"
is-non-interactive = true
` })
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-nav-providers"]')).not.toBeNull())
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-providers"]') as HTMLButtonElement)
    const account = container.querySelector('[data-testid="runtime-provider-native_fixture-account-home"]') as HTMLInputElement
    expect(account.required).toBe(false)
    fireEvent.input(account, { target: { value: '' } })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-save"]') as HTMLButtonElement)
    await waitFor(() => expect(apiMocks.saveRuntimeTomlConfig).toHaveBeenCalledOnce())
    expect(apiMocks.saveRuntimeTomlConfig.mock.calls[0]?.[0]).not.toContain('account-home = "/synthetic/native"')
  })

  it.each([false, true])('adds a Muse binding whether or not the model declares a byte budget (declared=%s)', async declared => {
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce({ ...richConfig,
      source_text: `${richConfig.source_text}
[providers.muse_fixture]
protocol = "muse-serve"
command = "muse"
account-home = "/synthetic/muse"
is-non-interactive = true
[models.muse_fixture]
api-name = "synthetic-model"
max-context = 200000
${declared ? 'max-prompt-bytes = 45678' : ''}
` })
    render(html`<${RuntimeTomlEditor} />`, container)
    await waitFor(() => expect(container.querySelector('[data-testid="runtime-toml-nav-bindings"]')).not.toBeNull())
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-bindings"]') as HTMLButtonElement)
    fireEvent.change(container.querySelector('[data-testid="runtime-add-binding-provider"]') as HTMLSelectElement, { target: { value: 'muse_fixture' } })
    fireEvent.change(container.querySelector('[data-testid="runtime-add-binding-model"]') as HTMLSelectElement, { target: { value: 'muse_fixture' } })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-binding-submit"]') as HTMLButtonElement)
    await waitFor(() => {
      const source = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
      expect(source).toContain('[muse_fixture.muse_fixture]')
    })
  })

  it('rejects a binding whose provider id is a reserved top-level namespace', async () => {
    // Hand-edited text can declare a provider named "models", so it shows up
    // in the binding form's provider list although the add-provider form
    // refuses the name. The server refuses it too (reserved_provider_ids), so
    // the binding form stops a binding pinned to it before any save.
    const configWithReservedProvider = {
      ...richConfig,
      source_text: `${richConfig.source_text}
[providers.models]
display-name = "Bad Provider"
protocol = "openai-http"
endpoint = "https://example.invalid/v1"
`,
    }
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(configWithReservedProvider)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-bindings"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-bindings"]') as HTMLButtonElement)

    const sourceBefore = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value

    fireEvent.change(container.querySelector('[data-testid="runtime-add-binding-provider"]') as HTMLSelectElement, {
      target: { value: 'models' },
    })
    fireEvent.change(container.querySelector('[data-testid="runtime-add-binding-model"]') as HTMLSelectElement, {
      target: { value: 'gpt' },
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-binding-submit"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-add-binding-error"]')?.textContent).toContain(
        '예약된 이름',
      )
    })
    // A rejected submit must never touch the draft source -- onAddBinding
    // should not have been called at all, not just "called harmlessly".
    const sourceAfter = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
    expect(sourceAfter).toBe(sourceBefore)
  })

  it('rejects a binding to an existing command-transport (CLI) provider', async () => {
    // Legacy/hand-edited data: a `command`-transport provider is parseable and
    // shows up in the binding dropdown even though the add-provider form can
    // no longer create one (RUNTIME_TOML_CREATABLE_PROTOCOLS/endpoint-only).
    // Runtime_adapter.provider_kind_of_cli_provider is hardcoded to None, so
    // materialize_config would silently drop any binding pinned to it.
    const configWithCliProvider = {
      ...richConfig,
      source_text: `${richConfig.source_text}
[providers.cli_like]
display-name = "CLI Like"
protocol = "openai-compatible-cli"
command = "provider-runtime --serve"
`,
    }
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(configWithCliProvider)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-bindings"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-bindings"]') as HTMLButtonElement)

    const sourceBefore = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value

    fireEvent.change(container.querySelector('[data-testid="runtime-add-binding-provider"]') as HTMLSelectElement, {
      target: { value: 'cli_like' },
    })
    fireEvent.change(container.querySelector('[data-testid="runtime-add-binding-model"]') as HTMLSelectElement, {
      target: { value: 'gpt' },
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-binding-submit"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-add-binding-error"]')?.textContent).toContain(
        'command(CLI)',
      )
    })
    const sourceAfter = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
    expect(sourceAfter).toBe(sourceBefore)
  })

  it('defers messages-http compatibility to the backend provider registry', async () => {
    const configWithMessagesProvider = {
      ...richConfig,
      source_text: `${richConfig.source_text}
[providers.kimi]
display-name = "Kimi"
protocol = "messages-http"
endpoint = "https://messages.example/v1"
`,
    }
    apiMocks.fetchRuntimeTomlConfig.mockResolvedValueOnce(configWithMessagesProvider)
    render(html`<${RuntimeTomlEditor} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-toml-nav-bindings"]')).not.toBeNull()
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-toml-nav-bindings"]') as HTMLButtonElement)

    const sourceBefore = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value

    fireEvent.change(container.querySelector('[data-testid="runtime-add-binding-provider"]') as HTMLSelectElement, {
      target: { value: 'kimi' },
    })
    fireEvent.change(container.querySelector('[data-testid="runtime-add-binding-model"]') as HTMLSelectElement, {
      target: { value: 'gpt' },
    })
    fireEvent.click(container.querySelector('[data-testid="runtime-add-binding-submit"]') as HTMLButtonElement)

    await waitFor(() => expect(container.querySelector('[data-testid="runtime-add-binding-error"]')).toBeNull())
    const sourceAfter = (container.querySelector('[data-testid="runtime-toml-source"]') as HTMLTextAreaElement).value
    expect(sourceAfter).not.toBe(sourceBefore)
    expect(sourceAfter).toContain('[kimi.gpt]')
  })
})
