import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  navigate: vi.fn(),
}))

vi.mock('../../router', () => ({
  navigate: mocks.navigate,
}))

import { WarroomGuideCallout } from './warroom-guide-callout'

describe('WarroomGuideCallout', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    mocks.navigate.mockClear()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders the experimental guidance and opens the expected shortcuts', () => {
    render(html`<${WarroomGuideCallout} />`, container)

    const text = container.textContent ?? ''
    expect(text).toContain('관제면은 실험 화면입니다.')
    expect(text).toContain('메인 메뉴 숨김')
    expect(text).toContain('운영 화면 안내')
    expect(text).toContain('실시간 개입 열기')

    const buttons = Array.from(container.querySelectorAll('button'))
    buttons[0]?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    buttons[1]?.dispatchEvent(new MouseEvent('click', { bubbles: true }))

    expect(mocks.navigate).toHaveBeenNthCalledWith(1, 'lab', { section: 'tools' })
    expect(mocks.navigate).toHaveBeenNthCalledWith(2, 'command', { section: 'intervene' })
  })
})
