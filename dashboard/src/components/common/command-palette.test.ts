import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const navigate = vi.fn()
const requestConfirm = vi.fn()
const runGarbageCollection = vi.fn().mockResolvedValue(undefined)
const route = signal<any>({ tab: 'code', params: { section: 'ide-shell' }, postId: null })
const missionAgentBriefs = signal<any[]>([])
const missionKeeperBriefs = signal<any[]>([])
const shellAuthSummary = signal<any>({
  effective_role: 'worker',
  default_role: 'worker',
  auth_error_code: null,
  auth_error_detail: null,
})

async function loadPalette() {
  vi.resetModules()
  vi.doMock('../../router', () => ({ navigate, route }))
  vi.doMock('./confirm-dialog', () => ({ requestConfirm }))
  vi.doMock('../flow-control/flow-control-state', () => ({
    runGarbageCollection,
  }))
  vi.doMock('../../mission-signals', () => ({
    missionAgentBriefs,
    missionKeeperBriefs,
  }))
  vi.doMock('../../store', () => ({ shellAuthSummary }))
  return import('./command-palette')
}

describe('CommandPalette', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    missionAgentBriefs.value = []
    missionKeeperBriefs.value = []
    route.value = { tab: 'code', params: { section: 'ide-shell' }, postId: null }
    shellAuthSummary.value = {
      effective_role: 'worker',
      default_role: 'worker',
      auth_error_code: null,
      auth_error_detail: null,
    }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.resetModules()
    vi.clearAllMocks()
    vi.doUnmock('../../router')
    vi.doUnmock('./confirm-dialog')
    vi.doUnmock('../flow-control/flow-control-state')
    vi.doUnmock('../../mission-signals')
    vi.doUnmock('../../store')
  })

  it('loads the web component lazily and wires navigation commands without reserved hotkeys', async () => {
    const { CommandPalette } = await loadPalette()

    render(html`<${CommandPalette} />`, container)
    await waitFor(() => {
      const palette = container.querySelector('ninja-keys') as (HTMLElement & {
        data?: Array<{ id: string; title: string; handler: () => void; hotkey?: string }>
      }) | null
      expect(palette).not.toBeNull()
      expect(palette?.data?.length).toBeGreaterThan(0)
    })

    const palette = container.querySelector('ninja-keys') as (HTMLElement & {
      data?: Array<{ id: string; title: string; handler: () => void; hotkey?: string }>
    }) | null

    expect(palette).not.toBeNull()
    expect(palette?.getAttribute('placeholder')).toContain('⌘/Ctrl+K')
    expect(palette?.data?.every((item) => item.hotkey == null)).toBe(true)

    const overview = palette?.data?.find((item) => item.id === 'nav-overview')
    overview?.handler()

    expect(navigate).toHaveBeenCalledWith('overview')
    expect(palette?.data?.find((item) => item.id === 'nav-workspace')?.title)
      .toBe('작업 화면으로 이동 (Work)')
  })

  it('registers a global IDE rails toggle command', async () => {
    const { CommandPalette } = await loadPalette()

    render(html`<${CommandPalette} />`, container)
    await waitFor(() => {
      const palette = container.querySelector('ninja-keys') as (HTMLElement & {
        data?: Array<{ id: string; title: string; handler: () => void }>
      }) | null
      expect(palette?.data?.some((item) => item.id === 'ide-toggle-rails')).toBe(true)
    })

    const palette = container.querySelector('ninja-keys') as (HTMLElement & {
      data?: Array<{ id: string; title: string; handler: () => void }>
    }) | null

    const toggle = palette?.data?.find((item) => item.id === 'ide-toggle-rails')
    expect(toggle?.title).toContain('숨기기')
    toggle?.handler()
    expect(navigate).toHaveBeenCalledWith('code', { section: 'ide-shell', rails: 'hidden' })

    route.value = { tab: 'code', params: { section: 'ide-shell', rails: 'hidden' }, postId: null }
    render(html`<${CommandPalette} />`, container)
    await waitFor(() => {
      const updated = container.querySelector('ninja-keys') as (HTMLElement & {
        data?: Array<{ id: string; title: string; handler: () => void }>
      }) | null
      expect(updated?.data?.find((item) => item.id === 'ide-toggle-rails')?.title).toContain('보이기')
    })
  })

  it('runs maintenance actions only after confirmation', async () => {
    shellAuthSummary.value = {
      effective_role: 'admin',
      default_role: 'worker',
      auth_error_code: null,
      auth_error_detail: null,
    }
    const { CommandPalette } = await loadPalette()

    render(html`<${CommandPalette} />`, container)
    await waitFor(() => {
      const palette = container.querySelector('ninja-keys') as (HTMLElement & {
        data?: Array<{ id: string; handler: () => Promise<void> | void }>
      }) | null
      expect(palette?.data?.length).toBeGreaterThan(0)
    })

    const palette = container.querySelector('ninja-keys') as (HTMLElement & {
      data?: Array<{ id: string; handler: () => Promise<void> | void }>
    }) | null

    requestConfirm.mockResolvedValueOnce(true)
    await palette?.data?.find((item) => item.id === 'action-gc')?.handler()
    expect(runGarbageCollection).toHaveBeenCalledTimes(1)

  })

  it('does not expose admin-only garbage collection to a worker', async () => {
    const { CommandPalette } = await loadPalette()

    render(html`<${CommandPalette} />`, container)
    await waitFor(() => {
      const palette = container.querySelector('ninja-keys') as (HTMLElement & {
        data?: Array<{ id: string }>
      }) | null
      expect(palette?.data?.length).toBeGreaterThan(0)
      expect(palette?.data?.some((item) => item.id === 'action-gc')).toBe(false)
    })
  })

  it('labels mission entities as command targets, not live runtime counts', async () => {
    missionAgentBriefs.value = [
      { agent_name: 'worker-a', display_name: 'Worker A', status: 'active' },
    ]
    missionKeeperBriefs.value = [
      { name: 'keeper-a', status: 'paused' },
      { name: 'keeper-b', status: 'busy' },
    ]
    const { CommandPalette } = await loadPalette()
    render(html`<${CommandPalette} />`, container)

    type PaletteItem = { id: string; section?: string; keywords?: string; handler: () => void }
    await waitFor(() => {
      const palette = container.querySelector('ninja-keys') as (HTMLElement & { data?: PaletteItem[] }) | null
      expect(palette?.data?.find((item) => item.id === 'nav-agent-worker-a')?.section)
        .toBe('Mission agent targets (1)')
      expect(palette?.data?.find((item) => item.id === 'nav-keeper-keeper-a')?.section)
        .toBe('Mission keeper targets (2)')
      expect(palette?.data?.find((item) => item.id === 'nav-keeper-keeper-a')?.keywords)
        .toContain('명령 대상 에이전트 1 / 키퍼 2')
    })

    const palette = container.querySelector('ninja-keys') as (HTMLElement & { data?: PaletteItem[] }) | null

    palette?.data?.find((item) => item.id === 'nav-agent-worker-a')?.handler()
    expect(navigate).toHaveBeenCalledWith('monitoring', { section: 'agents', agent: 'worker-a' })

    palette?.data?.find((item) => item.id === 'nav-keeper-keeper-a')?.handler()
    expect(navigate).toHaveBeenCalledWith('monitoring', { section: 'agents', keeper: 'keeper-a' })

  })
})
