import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { html } from 'htm/preact'
import { render } from 'preact'
import { waitFor } from '@testing-library/preact'
import {
  KeeperDetailSection,
  KeeperDetailHeaderInfo,
  KeeperDetailSectionRail,
  activeKeeperDetailSection,
} from './keeper-detail-shell'
import type { Keeper } from '../types'

async function flush() {
  await new Promise(resolve => setTimeout(resolve, 0))
}

describe('KeeperDetailSection', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    activeKeeperDetailSection.value = 'keeper-summary'
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders eyebrow, title, and children', () => {
    render(
      html`<${KeeperDetailSection}
        id="keeper-summary"
        eyebrow="OVERVIEW"
        title="Status Overview"
      >
        <div data-testid="child">Child</div>
      <//>`,
      container,
    )

    expect(container.textContent).toContain('OVERVIEW')
    expect(container.textContent).toContain('Status Overview')
    expect(container.querySelector('[data-testid="child"]')).not.toBeNull()
  })

  it('sets section id and aria-label', () => {
    activeKeeperDetailSection.value = 'keeper-debug'
    render(
      html`<${KeeperDetailSection}
        id="keeper-debug"
        eyebrow="DEBUG"
        title="Debug"
      >
        <span>content</span>
      <//>`,
      container,
    )

    const section = container.querySelector('section')
    expect(section?.getAttribute('id')).toBe('keeper-debug')
    expect(section?.getAttribute('aria-label')).toBe('Debug')
  })

  it('applies scroll margin and compact section styling', () => {
    activeKeeperDetailSection.value = 'keeper-config'
    render(
      html`<${KeeperDetailSection}
        id="keeper-config"
        eyebrow="CONFIG"
        title="Configuration"
      >
        <div>inner</div>
      <//>`,
      container,
    )

    const section = container.querySelector('section')
    expect(section?.classList.contains('scroll-mt-24')).toBe(true)
    expect(section?.classList.contains('rounded-[var(--r-2)]')).toBe(true)
    expect(section?.classList.contains('shadow-none')).toBe(true)
  })

  it('keeps locked-open primary sections visible without a collapse button', () => {
    activeKeeperDetailSection.value = 'keeper-comms'
    render(
      html`<${KeeperDetailSection}
        id="keeper-comms"
        eyebrow="CHAT"
        title="Conversation"
        defaultCollapsed=${true}
        lockedOpen=${true}
        variant="primary"
      >
        <div data-testid="chat-child">Chat child</div>
      <//>`,
      container,
    )

    expect(container.querySelector('[data-testid="chat-child"]')).not.toBeNull()
    expect(container.querySelector('button[aria-expanded]')).toBeNull()
    expect(container.textContent).not.toContain('기본')
    expect(container.querySelector('section')?.classList.contains('bg-transparent')).toBe(true)
  })
})

describe('KeeperDetailSectionRail', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    activeKeeperDetailSection.value = 'keeper-comms'
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders compact section navigation without long summary copy', () => {
    render(html`<${KeeperDetailSectionRail} />`, container)

    const nav = container.querySelector('nav[aria-label="키퍼 상세 섹션"]')
    expect(nav).not.toBeNull()
    expect(container.textContent).toContain('대화')
    expect(container.textContent).toContain('상태')
    expect(container.textContent).toContain('진단')
    expect(container.textContent).toContain('정체성')
    expect(container.textContent).toContain('설정')
    expect(container.textContent).toContain('디버그')
    expect(container.textContent).not.toContain('상태 기계, KPI')
    expect(container.textContent).not.toContain('실시간 대화와 세션 이벤트')
  })

  it('switches the active detail tab', async () => {
    render(html`
      <${KeeperDetailSectionRail} />
      <${KeeperDetailSection} id="keeper-comms" eyebrow="CHAT" title="Conversation">
        <div data-testid="comms-child">Comms</div>
      <//>
      <${KeeperDetailSection} id="keeper-runtime" eyebrow="RUN" title="Runtime">
        <div data-testid="runtime-child">Runtime</div>
      <//>
    `, container)

    expect(container.querySelector('[data-testid="comms-child"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="runtime-child"]')).toBeNull()

    const runtimeTab = Array.from(container.querySelectorAll('button[role="tab"]'))
      .find(button => button.textContent === '진단') as HTMLButtonElement | undefined
    expect(runtimeTab).toBeTruthy()
    runtimeTab!.click()
    await flush()

    expect(activeKeeperDetailSection.value).toBe('keeper-runtime')
    expect(container.querySelector('[data-testid="comms-child"]')).toBeNull()
    expect(container.querySelector('[data-testid="runtime-child"]')).not.toBeNull()
  })
})

describe('KeeperDetailHeaderInfo', () => {
  let container: HTMLDivElement
  const originalCreate = URL.createObjectURL
  const originalRevoke = URL.revokeObjectURL

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    URL.createObjectURL = () => 'blob:header-portrait'
    URL.revokeObjectURL = () => {}
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    URL.createObjectURL = originalCreate
    URL.revokeObjectURL = originalRevoke
    vi.unstubAllGlobals()
  })

  it('shows the keeper portrait when the live keeper has no emoji', async () => {
    const fetchMock = vi.fn(async (_path: string) =>
      new Response(new Blob([new Uint8Array([137, 80, 78, 71])], { type: 'image/png' }), { status: 200 }))
    vi.stubGlobal('fetch', fetchMock)
    const keeper = {
      name: 'wick-header-probe',
      portrait: { state: 'ready', equipment: { face: 'bare_face', neck: 'bare_neck', head: 'bare_head', hand: 'empty_hand', base: 'no_dish' } },
      status: 'active',
      phase: 'Running',
      lifecycle_phase: 'Running',
      model: 'claude-sonnet-4',
    } as Keeper

    render(
      html`<${KeeperDetailHeaderInfo}
        keeper=${keeper}
        titleId="keeper-title"
        phaseEnteredAtSec=${null}
        onClose=${() => {}}
      />`,
      container,
    )

    await waitFor(() => expect(container.querySelector('img[data-testid="keeper-portrait"]')).not.toBeNull())
    const portrait = container.querySelector('img[data-testid="keeper-portrait"]') as HTMLImageElement
    const request = new URL(fetchMock.mock.calls[0]![0], 'http://fixture.invalid')
    expect(request.pathname).toBe('/api/v1/keepers/wick-header-probe/portrait.png')
    expect(request.searchParams.get('size')).toBe('64')
    if (keeper.portrait?.state !== 'ready') throw new Error('Expected ready fixture portrait')
    expect(JSON.parse(request.searchParams.get('expected_equipment')!)).toEqual(keeper.portrait.equipment)
    expect(portrait.getAttribute('src')).toBe('blob:header-portrait')
    // The heading beside it already names the keeper.
    expect(portrait.getAttribute('alt')).toBe('')
    expect(container.querySelector('h2')?.textContent).toBe('wick-header-probe')
  })

  it('falls back to the keeper badge when the portrait cannot load', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('{"error":"not found"}', { status: 404 })))
    const keeper = {
      name: 'wick-header-probe',
      portrait: { state: 'ready', equipment: { face: 'bare_face', neck: 'bare_neck', head: 'bare_head', hand: 'empty_hand', base: 'no_dish' } },
      status: 'active',
      phase: 'Running',
      lifecycle_phase: 'Running',
      model: 'claude-sonnet-4',
    } as Keeper

    render(
      html`<${KeeperDetailHeaderInfo}
        keeper=${keeper}
        titleId="keeper-title"
        phaseEnteredAtSec=${null}
        onClose=${() => {}}
      />`,
      container,
    )

    await waitFor(() => expect(container.querySelector('[aria-label="wick-header-probe"]')).not.toBeNull())
    expect(container.querySelector('img[data-testid="keeper-portrait"]')).toBeNull()
  })

  it('keeps the declared emoji over the portrait', async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 500 }))
    vi.stubGlobal('fetch', fetchMock)
    const keeper = {
      name: 'wick-header-probe',
      portrait: { state: 'ready', equipment: { face: 'bare_face', neck: 'bare_neck', head: 'bare_head', hand: 'empty_hand', base: 'no_dish' } },
      emoji: '🕯️',
      status: 'active',
      phase: 'Running',
      lifecycle_phase: 'Running',
      model: 'claude-sonnet-4',
    } as Keeper

    render(
      html`<${KeeperDetailHeaderInfo}
        keeper=${keeper}
        titleId="keeper-title"
        phaseEnteredAtSec=${null}
        onClose=${() => {}}
      />`,
      container,
    )

    expect(container.querySelector('img[data-testid="keeper-portrait"]')).toBeNull()
    expect(container.textContent).toContain('🕯️')
    await flush()
    expect(fetchMock).not.toHaveBeenCalled()
  })
})
