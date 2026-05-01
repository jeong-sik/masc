// @ts-nocheck
// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { axe } from 'jest-axe'
import {
  currentZIndexMax,
  popLayer,
  pushLayer,
  resetZIndexStack,
} from './z-index-stack'

describe('z-index-stack', () => {
  let container: HTMLElement
  beforeEach(() => {
    resetZIndexStack()
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('allocates z-index based on layer base', () => {
    const z = pushLayer('dropdown')
    expect(z).toBeGreaterThanOrEqual(100)
    expect(currentZIndexMax()).toBe(z)
  })

  it('increments on successive pushes', () => {
    const z1 = pushLayer('dropdown')
    const z2 = pushLayer('dropdown')
    expect(z2).toBe(z1 + 1)
  })

  it('respects higher base layers', () => {
    pushLayer('dropdown') // 100+
    const z = pushLayer('modal')
    expect(z).toBeGreaterThanOrEqual(410)
  })

  it('pops current max only', () => {
    const z1 = pushLayer('dropdown')
    const z2 = pushLayer('dropdown')
    popLayer(z2)
    expect(currentZIndexMax()).toBe(z1)
    popLayer(z1)
    expect(currentZIndexMax()).toBeLessThan(z1)
  })

  it('ignores pop of non-max z-index', () => {
    const z1 = pushLayer('dropdown')
    pushLayer('dropdown')
    popLayer(z1)
    expect(currentZIndexMax()).toBeGreaterThan(z1)
  })

  it('renders accessibly', async () => {
    // Stack is pure logic; just ensure no axe regressions in empty doc
    expect(await axe(document.body)).toHaveNoViolations()
  })
})
