import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'

const fetchRuntimeParams = vi.fn()
const setRuntimeParam = vi.fn()
const clearRuntimeParam = vi.fn()
const showToast = vi.fn()

vi.mock('../api/dashboard-runtime', () => ({
  fetchRuntimeParams,
  setRuntimeParam,
  clearRuntimeParam,
}))
vi.mock('./common/toast', () => ({ showToast }))

const param = (over: Record<string, unknown> = {}) => ({
  key: 'keeper.hitl.thinking_blocks',
  current: 3,
  default: 3,
  has_override: false,
  meta: {
    description: 'Newest keeper thinking blocks kept in the HITL judgment bundle',
    value_type: 'int',
    min_value: 0,
    max_value: 1000,
  },
  ...over,
})

let container: HTMLElement

// The repo's own settle: preact schedules renders on a task, so microtasks
// alone return before the DOM the assertions read.
async function flushUi(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

async function mount() {
  const { RuntimeParamsPanel } = await import('./runtime-params-panel')
  render(html`<${RuntimeParamsPanel} />`, container)
  await flushUi()
}

describe('RuntimeParamsPanel', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.resetModules()
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('shows a knob with its bounds and description', async () => {
    fetchRuntimeParams.mockResolvedValue([param()])
    await mount()
    const row = container.querySelector('[data-testid="runtime-param-row"]')
    expect(row?.textContent).toContain('keeper.hitl.thinking_blocks')
    expect(row?.textContent).toContain('int')
    // Bounds matter: they are what the server will reject against, so an
    // operator should see them before typing rather than after.
    expect(row?.textContent).toContain('0 ~ 1000')
    expect(container.querySelector('[data-testid="runtime-param-current"]')?.textContent).toBe('3')
  })

  it('marks a knob somebody moved off its default', async () => {
    fetchRuntimeParams.mockResolvedValue([param({ current: 5, has_override: true })])
    await mount()
    expect(container.querySelector('[data-testid="runtime-param-overridden"]')).not.toBeNull()
    // The default stays visible, so "back to what" is answerable without
    // reading a config file.
    expect(container.querySelector('[data-testid="runtime-param-row"]')?.textContent).toContain('기본값 3')
  })

  it('refuses a value of the wrong type before sending it', async () => {
    // Sending it would make the server reject the write, and the row would sit
    // there looking saved.
    fetchRuntimeParams.mockResolvedValue([param()])
    await mount()
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'three'
    input.dispatchEvent(new Event('input'))
    await flushUi()
    const save = container.querySelector('button') as HTMLButtonElement
    save.click()
    await flushUi()
    expect(setRuntimeParam).not.toHaveBeenCalled()
    expect(showToast).toHaveBeenCalledWith(expect.stringContaining('정수'), 'error')
  })

  it('sends a well-typed value as that type, not as text', async () => {
    fetchRuntimeParams.mockResolvedValue([param()])
    setRuntimeParam.mockResolvedValue(undefined)
    await mount()
    const input = container.querySelector('input') as HTMLInputElement
    input.value = '5'
    input.dispatchEvent(new Event('input'))
    await flushUi()
    ;(container.querySelector('button') as HTMLButtonElement).click()
    await flushUi()
    expect(setRuntimeParam).toHaveBeenCalledWith('keeper.hitl.thinking_blocks', 5)
  })

  it('re-reads after a write instead of trusting what it sent', async () => {
    // The server decides what the value became. A screen that patches its own
    // row shows a number nobody is running on.
    fetchRuntimeParams
      .mockResolvedValueOnce([param()])
      .mockResolvedValueOnce([param({ current: 5, has_override: true })])
    setRuntimeParam.mockResolvedValue(undefined)
    await mount()
    const input = container.querySelector('input') as HTMLInputElement
    input.value = '5'
    input.dispatchEvent(new Event('input'))
    await flushUi()
    ;(container.querySelector('button') as HTMLButtonElement).click()
    await flushUi()
    expect(fetchRuntimeParams).toHaveBeenCalledTimes(2)
    expect(container.querySelector('[data-testid="runtime-param-current"]')?.textContent).toBe('5')
  })

  it('reports a read failure rather than showing an empty registry', async () => {
    // Empty means "nothing registered", which is a working state. A failed
    // read must not be able to look like one.
    fetchRuntimeParams.mockRejectedValue(new Error('params unreadable'))
    await mount()
    expect(container.textContent).toContain('params unreadable')
    expect(container.querySelectorAll('[data-testid="runtime-param-row"]').length).toBe(0)
  })
})
