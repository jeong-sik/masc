import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

void vi
vi.setConfig({ testTimeout: 120_000 })

async function flushUi(): Promise<void> {
  await act(async () => {
    for (let i = 0; i < 4; i += 1) {
      await Promise.resolve()
      await vi.advanceTimersByTimeAsync(0)
    }
  })
}

async function loadInspector(fetchKeeperToolCalls: ReturnType<typeof vi.fn>) {
  vi.resetModules()
  vi.doMock('../api/dashboard', () => ({
    fetchKeeperToolCalls,
  }))
  return import('./keeper-tool-call-inspector')
}

describe('KeeperToolCallInspector render', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    vi.useFakeTimers()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
    vi.resetModules()
    vi.doUnmock('../api/dashboard')
    vi.useRealTimers()
  })

  it('surfaces copy actions for expanded tool call input and output', async () => {
    const fetchKeeperToolCalls = vi.fn().mockResolvedValue({
      keeper: 'analyst',
      count: 1,
      source: 'tool_call_io',
      health: 'ok',
      entries: [
        {
          ts: 1_777_100_000,
          keeper: 'analyst',
          tool: 'keeper_bash',
          input: { cmd: 'pwd' },
          output: '{"ok":true}',
          success: true,
          duration_ms: 42,
          model: 'claude_code:auto',
        },
      ],
    })

    const { KeeperToolCallInspector } = await loadInspector(fetchKeeperToolCalls)
    await act(async () => {
      render(html`<${KeeperToolCallInspector} keeperName="analyst" />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const rowToggle = container.querySelector('button[aria-expanded="false"]') as HTMLButtonElement | null
    expect(rowToggle).not.toBeNull()
    await act(async () => {
      rowToggle?.click()
      await Promise.resolve()
    })
    await flushUi()

    const inputCopy = container.querySelector('[aria-label="도구 호출 입력 복사"]') as HTMLButtonElement | null
    const outputCopy = container.querySelector('[aria-label="도구 호출 출력 복사"]') as HTMLButtonElement | null
    expect(inputCopy).not.toBeNull()
    expect(outputCopy).not.toBeNull()
    expect(inputCopy?.getAttribute('title')).toBe('도구 호출 입력 복사')
    expect(outputCopy?.getAttribute('title')).toBe('도구 호출 출력 복사')
  })
})
