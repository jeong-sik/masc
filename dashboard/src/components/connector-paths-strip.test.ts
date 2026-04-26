// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  ConnectorPathsStrip,
  deriveMascPaths,
  _testResetPathsStrip,
} from './connector-paths-strip'
import type { GateConnectorInfo } from '../api/gate'

const mkConnector = (overrides: Partial<GateConnectorInfo> = {}): GateConnectorInfo => ({
  connector_id: overrides.connector_id ?? 'discord',
  display_name: overrides.display_name ?? 'Discord',
  channel: overrides.channel ?? 'discord',
  available: overrides.available ?? true,
  gate_healthy: overrides.gate_healthy ?? true,
  configured_bindings: overrides.configured_bindings ?? [],
  capabilities: overrides.capabilities ?? ['bindings'],
  ...(overrides as object),
}) as GateConnectorInfo

describe('deriveMascPaths', () => {
  it('falls back to repo-relative paths when no connector has names_path', () => {
    const paths = deriveMascPaths([])
    expect(paths.connectorsDir).toBeNull()
    expect(paths.logsDir).toBeNull()
    expect(paths.keepersDir).toBe('config/keepers/')
    expect(paths.sidecarsDir).toBe('sidecars/')
  })

  it('derives connectors + logs dir from standard names_path pattern', () => {
    const c = mkConnector({
      names_path: '/Users/alice/.masc/connectors/discord/names.json',
    } as never)
    const paths = deriveMascPaths([c])
    expect(paths.connectorsDir).toBe('/Users/alice/.masc/connectors/')
    expect(paths.logsDir).toBe('/Users/alice/.masc/logs/')
  })

  it('falls back when names_path is non-standard', () => {
    const c = mkConnector({ names_path: '/somewhere/else/names.json' } as never)
    const paths = deriveMascPaths([c])
    expect(paths.connectorsDir).toBeNull()
    expect(paths.logsDir).toBeNull()
  })

  it('ignores empty / whitespace names_path and falls through to next connector', () => {
    const c1 = mkConnector({ connector_id: 'discord', names_path: '' } as never)
    const c2 = mkConnector({
      connector_id: 'slack',
      names_path: '/home/bob/.masc/connectors/slack/names.json',
    } as never)
    const paths = deriveMascPaths([c1, c2])
    expect(paths.connectorsDir).toBe('/home/bob/.masc/connectors/')
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
    render(html`<${ConnectorPathsStrip} connectors=${[]} />`, container)
    expect(container.querySelector('[data-panel="connector-paths-strip"]')).not.toBeNull()
  })

  it('is collapsed by default — body rows are absent until expanded', () => {
    render(html`<${ConnectorPathsStrip} connectors=${[]} />`, container)
    expect(container.querySelector('[data-paths-row]')).toBeNull()
  })

  it('expands on header click and reveals keeper + sidecar rows even with no runtime', async () => {
    render(html`<${ConnectorPathsStrip} connectors=${[]} />`, container)
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

  it('surfaces Connectors + Logs rows once a connector reports a names_path', async () => {
    const c = mkConnector({
      names_path: '/Users/alice/.masc/connectors/discord/names.json',
    } as never)
    render(html`<${ConnectorPathsStrip} connectors=${[c]} />`, container)
    const toggle = container.querySelector<HTMLButtonElement>('[data-panel="connector-paths-strip"] button')!
    toggle.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    for (let i = 0; i < 4; i += 1) {
      await Promise.resolve()
      await new Promise(resolve => setTimeout(resolve, 0))
    }
    const rows = container.querySelectorAll('[data-paths-row]')
    const labels = Array.from(rows).map(r => r.getAttribute('data-paths-row'))
    expect(labels).toEqual(['커넥터', '로그', '키퍼', '사이드카'])
  })

  it('header shows runtime hint when no connector has names_path', () => {
    render(html`<${ConnectorPathsStrip} connectors=${[]} />`, container)
    const header = container.querySelector('[data-panel="connector-paths-strip"] button')!
    expect(header.textContent).toContain('런타임 미관찰')
  })
})
