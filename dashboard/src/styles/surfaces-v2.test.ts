// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import './surfaces-v2.css'

function makeContainer(): HTMLDivElement {
  const container = document.createElement('div')
  document.body.appendChild(container)
  return container
}

describe('surfaces-v2 CSS classes', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = makeContainer()
  })

  afterEach(() => {
    container.remove()
  })

  it('shared surface shell markup uses surf and surf-scroll classes', () => {
    container.innerHTML = '<div class="surf"><div class="surf-scroll"></div></div>'
    const surf = container.querySelector('.surf') as HTMLElement
    const scroll = container.querySelector('.surf-scroll') as HTMLElement
    expect(surf).not.toBeNull()
    expect(scroll).not.toBeNull()
    expect(surf.classList.contains('surf')).toBe(true)
    expect(scroll.classList.contains('surf-scroll')).toBe(true)
  })

  it('overview KPI grid markup uses ov-kpis and ov-kpi classes', () => {
    container.innerHTML = '<div class="ov-kpis"><div class="ov-kpi"></div></div>'
    const grid = container.querySelector('.ov-kpis') as HTMLElement
    const cell = container.querySelector('.ov-kpi') as HTMLElement
    expect(grid).not.toBeNull()
    expect(cell).not.toBeNull()
    expect(grid.classList.contains('ov-kpis')).toBe(true)
    expect(cell.classList.contains('ov-kpi')).toBe(true)
  })

  it('overview card renders with header', () => {
    container.innerHTML =
      '<div class="ov-card"><div class="ov-card-h"><h3>Title</h3></div></div>'
    const card = container.querySelector('.ov-card') as HTMLElement
    expect(card).not.toBeNull()
    expect(card.classList.contains('ov-card')).toBe(true)
    expect(card.querySelector('.ov-card-h')).not.toBeNull()
  })

  it('type ladder selector targets ov-head h1', () => {
    container.innerHTML = '<div class="ov-head"><h1>Overview</h1></div>'
    const h1 = container.querySelector('.ov-head h1') as HTMLElement
    expect(h1).not.toBeNull()
    expect(h1.tagName).toBe('H1')
  })
})
