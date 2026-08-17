// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  ConnectorPathsStrip,
  deriveMascPaths,
  _testResetPathsStrip,
} from './connector-paths-strip'

describe('deriveMascPaths', () => {
  it('returns the repo-relative conventions', () => {
    const paths = deriveMascPaths()
    expect(paths.keepersDir).toBe('config/keepers/')
    expect(paths.sidecarsDir).toBe('sidecars/')
  })
})

describe('ConnectorPathsStrip', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    _testResetPathsStrip()
  })
  afterEach(() => {
    document.body.removeChild(container)
  })

  it('mounts the paths strip panel', () => {
    render(html`<${ConnectorPathsStrip} />`, container)
    expect(container.querySelector('[data-panel="connector-paths-strip"]')).not.toBeNull()
    expect(container.querySelector('.v2-connector-paths-strip')).not.toBeNull()
  })

  it('is collapsed by default — body rows are absent until expanded', () => {
    render(html`<${ConnectorPathsStrip} />`, container)
    expect(container.querySelector('[data-paths-row]')).toBeNull()
  })

  it('expands on header click and reveals keeper + sidecar rows', async () => {
    render(html`<${ConnectorPathsStrip} />`, container)
    const toggle = container.querySelector<HTMLButtonElement>('[data-panel="connector-paths-strip"] button')!
    toggle.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    for (let i = 0; i < 4; i += 1) {
      await Promise.resolve()
      await new Promise(resolve => setTimeout(resolve, 0))
    }
    const rows = container.querySelectorAll('[data-paths-row]')
    const labels = Array.from(rows).map(r => r.getAttribute('data-paths-row'))
    expect(labels).toEqual(['키퍼', '사이드카'])
  })
})
