// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { MoleculeArtifact } from './artifact-molecule'
import { MoleculeAttach } from './attach-molecule'

describe('MoleculeArtifact', () => {
  let host: HTMLDivElement
  beforeEach(() => { host = document.createElement('div'); document.body.appendChild(host) })
  afterEach(() => { render(null, host); host.remove() })

  it('renders the design artifact row (af-ico/af-meta/af-name/af-sub/af-btn)', () => {
    render(html`<${MoleculeArtifact} kind="md" name="report.md" size="1.2 KB" note="PATCH" data="data:text/markdown;base64,IyB4" />`, host)
    const el = host.firstElementChild as HTMLElement
    expect(el.classList.contains('artifact')).toBe(true)
    expect(el.querySelector('.af-ico')!.textContent).toBe('⌹')
    expect(el.querySelector('.af-name')!.textContent).toBe('report.md')
    expect(el.querySelector('.af-sub')!.textContent).toBe('MD · 1.2 KB · PATCH')
    // no onOpen handler → no fake "열기" button; download is enabled (has data)
    expect(el.querySelectorAll('.af-btn')).toHaveLength(1)
    expect((el.querySelector('.af-btn') as HTMLButtonElement).disabled).toBe(false)
  })

  it('disables download without a data payload and renders onOpen when given', () => {
    const onOpen = vi.fn()
    render(html`<${MoleculeArtifact} name="x.md" onOpen=${onOpen} />`, host)
    const btns = host.querySelectorAll('.af-btn')
    expect(btns).toHaveLength(2)
    expect((btns[0] as HTMLButtonElement).textContent).toBe('열기')
    ;(btns[0] as HTMLButtonElement).click()
    expect(onOpen).toHaveBeenCalledOnce()
    expect((btns[1] as HTMLButtonElement).disabled).toBe(true)
  })
})

describe('MoleculeAttach', () => {
  let host: HTMLDivElement
  beforeEach(() => { host = document.createElement('div'); document.body.appendChild(host) })
  afterEach(() => { render(null, host); host.remove() })

  it('renders attach chrome with a real image src', () => {
    render(html`
      <${MoleculeAttach}
        name="shot.png"
        dims="1920×1080"
        src="data:image/png;base64,iVBORw0KGgo="
        via="dashboard"
        size="84 KB"
        tag="vision"
      />
    `, host)
    const el = host.firstElementChild as HTMLElement
    expect(el.classList.contains('attach')).toBe(true)
    expect(el.querySelector('.attach-hd .attach-clip')).not.toBeNull()
    expect(el.querySelector('.attach-name')!.textContent).toBe('shot.png')
    expect(el.querySelector('.attach-dims')!.textContent).toBe('1920×1080')
    expect(el.querySelector('.attach-frame img')!.getAttribute('src')).toContain('data:image/png')
    expect(el.querySelector('.attach-cap .attach-tag')!.textContent).toBe('vision')
    expect(el.querySelector('.attach-cap')!.textContent).toContain('dashboard · 84 KB')
  })

  it('falls back to img-ph for unsafe or missing src', () => {
    render(html`<${MoleculeAttach} name="x.png" src="javascript:alert(1)" />`, host)
    expect(host.querySelector('img')).toBeNull()
    expect(host.querySelector('.img-ph')!.textContent).toContain('첨부 이미지')
    render(null, host)
    render(html`<${MoleculeAttach} name="x.png" ph="미리보기 없음" />`, host)
    expect(host.querySelector('.img-ph')!.textContent).toBe('미리보기 없음')
  })

  it('omits the caption row when neither via/size nor tag exist', () => {
    render(html`<${MoleculeAttach} name="x.png" svg="<svg></svg>" />`, host)
    expect(host.querySelector('.attach-cap')).toBeNull()
    // svg branch taken — the sanitizer fallback escapes markup under happy-dom,
    // so assert the carrier span rather than a live <svg> element.
    expect(host.querySelector('.attach-frame > span')).not.toBeNull()
  })
})
