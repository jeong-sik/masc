// @ts-nocheck
// @vitest-environment happy-dom
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, h } from 'preact'
import { KeeperSpawnPanel } from './keeper-spawn-panel'
import { showSpawnPanel } from './keeper-spawn-state'

vi.mock('./persona-browser', () => ({
  PersonaBrowser: () => h('div', { className: 'persona-browser-mock' }, 'Browser'),
}))

vi.mock('./persona-generator', () => ({
  PersonaGenerator: () => h('div', { className: 'persona-generator-mock' }, 'Generator'),
}))

describe('KeeperSpawnPanel', () => {
  beforeEach(() => {
    showSpawnPanel.value = false
  })

  it('renders collapsed with add button', () => {
    const container = document.createElement('div')
    render(h(KeeperSpawnPanel), container)
    expect(container.textContent).toContain('+ 키퍼 생성')
  })

  it('expands when showSpawnPanel is true', () => {
    showSpawnPanel.value = true
    const container = document.createElement('div')
    render(h(KeeperSpawnPanel), container)
    expect(container.textContent).toContain('키퍼 생성')
    expect(container.textContent).toContain('닫기')
  })

  it('shows persona browser by default in expanded mode', () => {
    showSpawnPanel.value = true
    const container = document.createElement('div')
    render(h(KeeperSpawnPanel), container)
    expect(container.textContent).toContain('Browser')
  })

  it('switches to generate tab on click', () => {
    showSpawnPanel.value = true
    const container = document.createElement('div')
    render(h(KeeperSpawnPanel), container)
    const buttons = container.querySelectorAll('button')
    const generateBtn = Array.from(buttons).find((b) => b.textContent?.includes('새 페르소나'))
    expect(generateBtn).not.toBeUndefined()
    generateBtn!.click()
    render(null, container)
    render(h(KeeperSpawnPanel), container)
    expect(container.textContent).toContain('Generator')
  })

  it('switches to direct tab on click', () => {
    showSpawnPanel.value = true
    const container = document.createElement('div')
    render(h(KeeperSpawnPanel), container)
    const buttons = container.querySelectorAll('button')
    const directBtn = Array.from(buttons).find((b) => b.textContent?.includes('직접 생성'))
    expect(directBtn).not.toBeUndefined()
    directBtn!.click()
    render(null, container)
    render(h(KeeperSpawnPanel), container)
    expect(container.textContent).toContain('masc_keeper_up')
  })

  it('closes panel on 닫기 click', () => {
    showSpawnPanel.value = true
    const container = document.createElement('div')
    render(h(KeeperSpawnPanel), container)
    const buttons = container.querySelectorAll('button')
    const closeBtn = Array.from(buttons).find((b) => b.textContent?.includes('닫기'))
    expect(closeBtn).not.toBeUndefined()
    closeBtn!.click()
    expect(showSpawnPanel.value).toBe(false)
  })

  it('opens panel on + 키퍼 생성 click', () => {
    showSpawnPanel.value = false
    const container = document.createElement('div')
    render(h(KeeperSpawnPanel), container)
    const buttons = container.querySelectorAll('button')
    const openBtn = Array.from(buttons).find((b) => b.textContent?.includes('+ 키퍼 생성'))
    expect(openBtn).not.toBeUndefined()
    openBtn!.click()
    expect(showSpawnPanel.value).toBe(true)
  })
})
