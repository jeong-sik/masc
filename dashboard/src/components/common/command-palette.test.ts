import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const navigate = vi.fn()
const requestConfirm = vi.fn()
const runGarbageCollection = vi.fn().mockResolvedValue(undefined)
const cleanupZombies = vi.fn().mockResolvedValue(undefined)
const missionSnapshot = signal<any>(null)
const missionAgentBriefs = signal<any[]>([])
const missionKeeperBriefs = signal<any[]>([])

async function loadPalette() {
  vi.resetModules()
  vi.doMock('../../router', () => ({ navigate }))
  vi.doMock('./confirm-dialog', () => ({ requestConfirm }))
  vi.doMock('../flow-control/flow-control-state', () => ({
    cleanupZombies,
    runGarbageCollection,
  }))
  vi.doMock('../../mission-signals', () => ({
    missionSnapshot,
    missionAgentBriefs,
    missionKeeperBriefs,
  }))
  return import('./command-palette')
}

describe('CommandPalette', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    missionSnapshot.value = null
    missionAgentBriefs.value = []
    missionKeeperBriefs.value = []
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
  })

  it('loads the web component lazily and wires navigation commands without reserved hotkeys', async () => {
    const { CommandPalette } = await loadPalette()

    render(html`<${CommandPalette} />`, container)
    await waitFor(() => {
      const palette = container.querySelector('ninja-keys') as (HTMLElement & {
        data?: Array<{ id: string; handler: () => void; hotkey?: string }>
      }) | null
      expect(palette).not.toBeNull()
      expect(palette?.data?.length).toBeGreaterThan(0)
    })

    const palette = container.querySelector('ninja-keys') as (HTMLElement & {
      data?: Array<{ id: string; handler: () => void; hotkey?: string }>
    }) | null

    expect(palette).not.toBeNull()
    expect(palette?.getAttribute('placeholder')).toContain('⌘/Ctrl+K')
    expect(palette?.data?.every((item) => item.hotkey == null)).toBe(true)

    const overview = palette?.data?.find((item) => item.id === 'nav-overview')
    overview?.handler()

    expect(navigate).toHaveBeenCalledWith('overview')
  })

  it('runs maintenance actions only after confirmation', async () => {
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

    requestConfirm.mockResolvedValueOnce(false)
    await palette?.data?.find((item) => item.id === 'action-zombie')?.handler()
    expect(cleanupZombies).not.toHaveBeenCalled()
  })

  it('indexes live mission sessions in the palette', async () => {
    missionSnapshot.value = {
      sessions: [
        { session_id: 'sess-1', goal: 'fallback brief', status: 'running' },
      ],
    }

    const { CommandPalette } = await loadPalette()
    render(html`<${CommandPalette} />`, container)

    await waitFor(() => {
      const palette = container.querySelector('ninja-keys') as (HTMLElement & {
        data?: Array<{ id: string; title: string }>
      }) | null
      expect(palette?.data?.some((item) => item.id === 'nav-session-sess-1')).toBe(true)
    })
  })
})
