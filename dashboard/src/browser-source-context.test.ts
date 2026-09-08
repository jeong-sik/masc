import { describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import { sourceHtml } from '../dev/source-context-runtime'
import { instrumentSource, sourceContextPlugin } from '../dev/source-context-plugin'
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'

const root = '/project'
describe('development browser source context', () => {
  it('uses parsed imports/templates, preserves nested expressions and reports original positions', () => {
    const code = `import { html as view } from 'htm/preact'\nconst label = "한글🙂"\nexport const node = view\`<button>\${label}</button>\``
    const transformed = instrumentSource(code, '/project/dashboard/src/example.ts', root)!
    expect(transformed.code).toContain('\\"file\\":\\"dashboard/src/example.ts\\"')
    expect(transformed.code).toContain('\\"line\\":3')
    expect(transformed.code).toContain('${label}')
    expect(transformed.map.sourcesContent).toEqual([code])
  })
  it('does not transform a shadowed tag or unrelated tagged template', () => {
    const code = `import { html } from 'htm/preact'; function other(html) { return html\`<p>wrong</p>\` }`
    expect(instrumentSource(code, '/project/dashboard/src/example.ts', root)).toBeUndefined()
    expect(instrumentSource('const node = html`<p>other library</p>`', '/project/dashboard/src/example.ts', root)).toBeUndefined()
    for (const expression of [
      'function html(x) { return html`<p>local function</p>` }',
      'class html { method() { return html`<p>local class</p>` } }',
    ]) {
      expect(instrumentSource(`import { html } from 'htm/preact'; const local = ${expression}`,
        '/project/dashboard/src/example.ts', root)).toBeUndefined()
    }
  })
  it('allows a cyclic dependency to call a hoisted component before its module initializes', () => {
    const directory = mkdtempSync(join(tmpdir(), 'masc-source-cycle-'))
    try {
      const code = 'import {html} from "htm/preact"; import "./b.mjs"; export function A(){return html`<div/>`;}'
      const transformed = instrumentSource(code, '/project/dashboard/src/a.js', root)!
      writeFileSync(join(directory, 'a.mjs'), transformed.code
        .replace('/@masc/source-context-runtime', './runtime.mjs').replace('htm/preact', './htm.mjs'))
      writeFileSync(join(directory, 'b.mjs'), 'import {A} from "./a.mjs"; export const value=A();')
      writeFileSync(join(directory, 'htm.mjs'), 'export function html(strings){return strings[0];}')
      writeFileSync(join(directory, 'runtime.mjs'), 'export function sourceHtml(){return strings => strings[0];}')
      const result = spawnSync(process.execPath, ['--input-type=module', '-e',
        'await import("./a.mjs"); const {value}=await import("./b.mjs"); process.stdout.write(value);'],
      {cwd:directory, encoding:'utf8'})
      expect(result.stderr).toBe('')
      expect(result.status).toBe(0)
      expect(result.stdout).toBe('<div/>')
    } finally { rmSync(directory, {recursive:true, force:true}) }
  })
  it('keeps static HTM caching across lazy factory calls and separates changed source', () => {
    const metadata = {file:'dashboard/src/a.ts',line:1,column:1,digest:'original'}
    const source = JSON.stringify(metadata)
    function component() { return sourceHtml(source)`<div>static cached node</div>` }
    expect(component()).toBe(component())
    expect(sourceHtml(source)).toBe(sourceHtml(source))
    expect(sourceHtml(JSON.stringify({...metadata,digest:'edited'}))).not.toBe(sourceHtml(source))
  })
  it('keeps HTM nested site locations, handlers, keys and refs', () => {
    const parent = sourceHtml('parent'), child = sourceHtml('child')
    const host = document.createElement('div')
    let clicked = 0, reference: Element | null = null
    function Button() { return child`<button ref=${(element: Element) => { reference = element }} onClick=${() => { clicked++ }}>Click</button>` }
    render(parent`<section><${Button} />${[1,2].map(i => child`<span key=${i}>${i}</span>`)}</section>`,host)
    expect(host.querySelector('section')?.getAttribute('data-masc-source')).toBe('parent')
    expect(host.querySelector('button')?.getAttribute('data-masc-source')).toBe('child')
    expect(reference).toBe(host.querySelector('button'))
    host.querySelector('button')!.click()
    expect(clicked).toBe(1)
    expect([...host.querySelectorAll('span')].map(el => el.textContent)).toEqual(['1','2'])
    render(h('div',null),host)
    expect(reference).toBeNull()
  })
  it('adds JSX source after spread props and only to native elements', () => {
    const code = 'export const node = <div {...props}><Button /><_Private /><$Widget /><x-Widget /><span>word</span></div>'
    const output = instrumentSource(code,'/project/dashboard/src/a.tsx',root)!
    expect(output.code).toContain('<div {...props} data-masc-source=')
    expect(output.code).toContain('<Button />')
    expect(output.code).toContain('<_Private />')
    expect(output.code).toContain('<$Widget />')
    expect(output.code).toContain('<x-Widget data-masc-source=')
    expect(output.map.sourcesContent).toEqual([code])
  })
  it('is dev-server only', () => { expect(sourceContextPlugin().apply).toBe('serve') })
})
