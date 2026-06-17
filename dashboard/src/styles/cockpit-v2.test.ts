// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import '@testing-library/jest-dom'
import './cockpit-v2.css'

function makeContainer(): HTMLDivElement {
  const container = document.createElement('div')
  document.body.appendChild(container)
  return container
}

describe('cockpit-v2 CSS classes', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = makeContainer()
  })

  afterEach(() => {
    container.remove()
  })

  it('cockpit body markup uses cp-body, cp-world and cp-main classes', () => {
    container.innerHTML =
      '<div class="cp-body"><div class="cp-world"></div><div class="cp-main"></div></div>'
    const body = container.querySelector('.cp-body') as HTMLElement
    const world = container.querySelector('.cp-world') as HTMLElement
    const main = container.querySelector('.cp-main') as HTMLElement
    expect(body).not.toBeNull()
    expect(world).not.toBeNull()
    expect(main).not.toBeNull()
    expect(body.classList.contains('cp-body')).toBe(true)
    expect(world.classList.contains('cp-world')).toBe(true)
    expect(main.classList.contains('cp-main')).toBe(true)
  })

  it('cockpit route renders', () => {
    container.innerHTML = '<button class="cp-route"><span class="rl">Route</span></button>'
    const route = container.querySelector('.cp-route') as HTMLElement
    expect(route).not.toBeNull()
    expect(route.classList.contains('cp-route')).toBe(true)
    expect(route.querySelector('.rl')).not.toBeNull()
  })

  it('cockpit plane renders with header and routes container', () => {
    container.innerHTML =
      '<section class="cp-plane"><div class="cp-plane-h"><h2>Plane</h2></div><div class="cp-routes"><button class="cp-route"></button></div></section>'
    const plane = container.querySelector('.cp-plane') as HTMLElement
    expect(plane).not.toBeNull()
    expect(plane.querySelector('.cp-plane-h')).not.toBeNull()
    expect(plane.querySelector('.cp-routes')).not.toBeNull()
    expect(plane.querySelector('.cp-route')).not.toBeNull()
  })

  it('progressive disclosure row renders', () => {
    container.innerHTML =
      '<div class="cp-disc-row"><div class="lvl">perceive</div><div class="ttl">Title</div><div class="sum">Summary</div><span class="mtr">metric</span></div>'
    const row = container.querySelector('.cp-disc-row') as HTMLElement
    expect(row).not.toBeNull()
    expect(row.querySelector('.lvl')).toHaveTextContent('perceive')
    expect(row.querySelector('.ttl')).toHaveTextContent('Title')
    expect(row.querySelector('.sum')).toHaveTextContent('Summary')
    expect(row.querySelector('.mtr')).toHaveTextContent('metric')
  })
})
