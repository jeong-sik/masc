import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { html } from 'htm/preact'
import { render } from 'preact'
import { KeeperDetailSection, KeeperDetailSectionRail } from './keeper-detail-shell'

describe('KeeperDetailSection', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
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
})
