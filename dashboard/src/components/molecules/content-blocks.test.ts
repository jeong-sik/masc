// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { MoleculeCodeBlock, MoleculeShellBlock, MoleculeTable } from './content-blocks'

describe('MoleculeCodeBlock', () => {
  let host: HTMLDivElement
  beforeEach(() => { host = document.createElement('div'); document.body.appendChild(host) })
  afterEach(() => { render(null, host); host.remove() })

  it('renders code-block with code-cap and mono pre', () => {
    render(html`<${MoleculeCodeBlock} cap="keeper.ts" html="const <b>a</b> = 1" />`, host)
    const el = host.firstElementChild as HTMLElement
    expect(el.classList.contains('code-block')).toBe(true)
    expect(el.querySelector('.code-cap')!.textContent).toBe('keeper.ts')
    // happy-dom fails the DOMPurify smoke test, so the lib's fallback escapes
    // markup here; in a real browser the <b> passes through sanitized.
    expect(el.querySelector('pre.mono code')!.textContent).toBe('const <b>a</b> = 1')
  })

  it('omits the caption bar when cap is absent', () => {
    render(html`<${MoleculeCodeBlock} html="x = 1" />`, host)
    expect(host.querySelector('.code-cap')).toBeNull()
  })

  it('sanitizes injected html', () => {
    render(html`<${MoleculeCodeBlock} html="${'<script>alert(1)</script>safe'}" />`, host)
    expect(host.querySelector('script')).toBeNull()
    expect(host.querySelector('code')!.textContent).toContain('safe')
  })
})

describe('MoleculeShellBlock', () => {
  let host: HTMLDivElement
  beforeEach(() => { host = document.createElement('div'); document.body.appendChild(host) })
  afterEach(() => { render(null, host); host.remove() })

  it('renders shell chrome, lines with sh-prompt on cmd, and an ok exit', () => {
    render(html`
      <${MoleculeShellBlock}
        title="keeper@wt"
        lines=${[{ t: 'cmd', v: 'dune build' }, { t: 'out', v: 'done' }, { t: 'err', v: 'warn' }]}
        exit=${0}
        dur="1.2s"
      />
    `, host)
    const el = host.firstElementChild as HTMLElement
    expect(el.classList.contains('shell-block')).toBe(true)
    expect(el.querySelector('.shell-bar .shell-title')!.textContent).toBe('keeper@wt')
    const lines = el.querySelectorAll('.sh-ln')
    expect(lines).toHaveLength(3)
    expect(lines[0]!.classList.contains('cmd')).toBe(true)
    expect(lines[0]!.querySelector('.sh-prompt')!.textContent).toBe('$ ')
    expect(lines[1]!.className.trim()).toBe('sh-ln')
    expect(lines[2]!.classList.contains('err')).toBe(true)
    expect(el.querySelector('.shell-exit.ok')!.textContent).toBe('exit 0 · 1.2s')
  })

  it('marks non-zero exit as fail and omits the footer when exit is absent', () => {
    render(html`<${MoleculeShellBlock} lines=${[{ t: 'cmd', v: 'x' }]} exit=${2} />`, host)
    expect(host.querySelector('.shell-exit.fail')!.textContent).toBe('exit 2')
    render(null, host)
    render(html`<${MoleculeShellBlock} lines=${[]} />`, host)
    expect(host.querySelector('.shell-exit')).toBeNull()
    // default title from the design
    expect(host.querySelector('.shell-title')!.textContent).toBe('keeper@worktree')
  })
})

describe('MoleculeTable', () => {
  let host: HTMLDivElement
  beforeEach(() => { host = document.createElement('div'); document.body.appendChild(host) })
  afterEach(() => { render(null, host); host.remove() })

  it('renders md-table with num/muted cell modifiers', () => {
    render(html`
      <${MoleculeTable}
        head=${['Keeper', { v: 'Turns', num: true }]}
        rows=${[['iron-claw', { v: '88', num: true }, { v: 'running', muted: true }]]}
      />
    `, host)
    const table = host.querySelector('table.md-table')!
    expect(table).not.toBeNull()
    expect(table.querySelectorAll('th')[1]!.classList.contains('num')).toBe(true)
    const cells = table.querySelectorAll('tbody td')
    expect(cells[1]!.classList.contains('num')).toBe(true)
    expect(cells[2]!.classList.contains('muted')).toBe(true)
  })
})
