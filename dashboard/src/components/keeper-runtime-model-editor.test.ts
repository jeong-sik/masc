import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { KeeperConfig } from '../types'
import type { KeeperConfigLoadStatus } from './keeper-detail-source'

// Mutable test state, hoisted so the mock factories below can close over it.
const refs = vi.hoisted(() => ({
  config: null as unknown,
  status: 'loaded' as string,
  patch: vi.fn(),
  applied: vi.fn(),
  load: vi.fn(),
}))

// Only [patchKeeperConfig] is exercised; the other two satisfy keeper-config-panel's
// real module-level imports when [vi.importActual] loads it below.
vi.mock('../api/dashboard', () => ({
  patchKeeperConfig: refs.patch,
  fetchKeeperConfig: vi.fn(),
  fetchDashboardGoalsTree: vi.fn(),
}))

// Keep the real [InlineSelectRow] (via ...actual); override the shared-config
// accessors so each test drives the loaded config directly.
vi.mock('./keeper-config-panel', async () => {
  const actual = await vi.importActual<typeof import('./keeper-config-panel')>('./keeper-config-panel')
  return {
    ...actual,
    peekLoadedKeeperConfig: (_name: string) => refs.config as KeeperConfig | null,
    peekKeeperConfigLoadStatus: (_name: string) => refs.status as KeeperConfigLoadStatus,
    loadKeeperConfig: refs.load,
    applyKeeperConfigUpdate: refs.applied,
  }
})

vi.mock('./common/toast', () => ({ showToast: vi.fn() }))

import { KeeperRuntimeModelEditor, canEditRuntime, uniqueNonEmpty } from './keeper-runtime-model-editor'

async function flush() {
  await new Promise(resolve => setTimeout(resolve, 0))
}

// Partial config carrying only the fields the editor reads. The single cast is
// confined to this helper; the component never sees an untyped value.
function makeConfig(
  execution: Partial<KeeperConfig['execution']> = {},
  sources: Partial<KeeperConfig['sources']> = {},
): KeeperConfig {
  return {
    execution: {
      selected_runtime_id: 'a.one',
      selected_runtime_canonical: 'a.one',
      runtime_options: ['a.one', 'b.two'],
      ...execution,
    },
    sources: {
      default_source_kind: 'toml',
      default_manifest_path: '/tmp/config/keepers/echo.toml',
      ...sources,
    },
  } as unknown as KeeperConfig
}

describe('uniqueNonEmpty', () => {
  it('drops empties and dedupes, preserving first-seen order', () => {
    expect(uniqueNonEmpty(['a.one', '', '  ', 'b.two', 'a.one', ' b.two '])).toEqual(['a.one', 'b.two'])
  })

  it('returns [] for all-empty input', () => {
    expect(uniqueNonEmpty(['', '   '])).toEqual([])
  })
})

describe('canEditRuntime', () => {
  it('is true only for a toml source with a manifest path', () => {
    expect(canEditRuntime(makeConfig({}, { default_source_kind: 'toml', default_manifest_path: '/x.toml' }))).toBe(true)
  })

  it('is false for a persona source', () => {
    expect(canEditRuntime(makeConfig({}, { default_source_kind: 'persona', default_manifest_path: '/x.toml' }))).toBe(false)
  })

  it('is false when the toml manifest path is missing', () => {
    expect(canEditRuntime(makeConfig({}, { default_source_kind: 'toml', default_manifest_path: null }))).toBe(false)
  })
})

describe('KeeperRuntimeModelEditor', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    refs.config = null
    refs.status = 'loaded'
    refs.patch.mockReset()
    refs.applied.mockReset()
    refs.load.mockReset()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders an editable model selector for a toml-sourced keeper', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one', runtime_options: ['a.one', 'b.two'] })
    render(html`<${KeeperRuntimeModelEditor} keeperName="editable-keeper" />`, container)
    await flush()

    expect(container.textContent).toContain('런타임 model')
    expect(container.textContent).toContain('a.one')
    const select = container.querySelector('select[aria-label="model"]') as HTMLSelectElement | null
    expect(select).not.toBeNull()
    expect(select!.value).toBe('a.one')
  })

  it('patches runtime_id with the selected model and updates shared config', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one', runtime_options: ['a.one', 'b.two'] })
    refs.patch.mockResolvedValueOnce(makeConfig({ selected_runtime_id: 'b.two', runtime_options: ['a.one', 'b.two'] }))

    render(html`<${KeeperRuntimeModelEditor} keeperName="patch-keeper" />`, container)
    await flush()

    const select = container.querySelector('select[aria-label="model"]') as HTMLSelectElement
    select.value = 'b.two'
    select.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()

    const saveButton = Array.from(container.querySelectorAll('button')).find(b => b.textContent?.includes('저장'))
    expect(saveButton).toBeTruthy()
    saveButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()

    expect(refs.patch).toHaveBeenCalledWith('patch-keeper', { runtime_id: 'b.two' })
    expect(refs.applied).toHaveBeenCalledTimes(1)
  })

  it('does not patch when the selection equals the current value', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one', runtime_options: ['a.one', 'b.two'] })
    render(html`<${KeeperRuntimeModelEditor} keeperName="noop-keeper" />`, container)
    await flush()

    // No selection change → save button is disabled and patch is never called.
    const saveButton = Array.from(container.querySelectorAll('button')).find(b => b.textContent?.includes('저장'))
    expect((saveButton as HTMLButtonElement).disabled).toBe(true)
    saveButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    expect(refs.patch).not.toHaveBeenCalled()
  })

  it('shows an actionable read-only hint for a non-toml keeper', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one' }, { default_source_kind: 'persona', default_manifest_path: null })
    render(html`<${KeeperRuntimeModelEditor} keeperName="persona-keeper" />`, container)
    await flush()

    expect(container.querySelector('select[aria-label="model"]')).toBeNull()
    expect(container.textContent).toContain('편집 가능한 TOML 소스가 아니')
    // Hint names the exact file to add so the operator can unlock editing.
    expect(container.textContent).toContain('persona-keeper.toml')
  })

  it('clears a pending selection when the viewed keeper changes', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one', runtime_options: ['a.one', 'b.two'] })
    render(html`<${KeeperRuntimeModelEditor} keeperName="keeper-alpha" />`, container)
    await flush()

    const select = container.querySelector('select[aria-label="model"]') as HTMLSelectElement
    select.value = 'b.two'
    select.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()
    expect((container.querySelector('select[aria-label="model"]') as HTMLSelectElement).value).toBe('b.two')

    // Navigate to a different keeper: the stale pending 'b.two' must not leak.
    refs.config = makeConfig({ selected_runtime_id: 'c.three', runtime_options: ['c.three', 'b.two'] })
    render(html`<${KeeperRuntimeModelEditor} keeperName="keeper-beta" />`, container)
    await flush()

    expect((container.querySelector('select[aria-label="model"]') as HTMLSelectElement).value).toBe('c.three')
  })

  it('renders a loading state until the config is available', async () => {
    refs.config = null
    refs.status = 'loading'
    render(html`<${KeeperRuntimeModelEditor} keeperName="loading-keeper" />`, container)
    await flush()
    expect(container.textContent).toContain('불러오는 중')
  })
})
