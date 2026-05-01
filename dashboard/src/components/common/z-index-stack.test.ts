import { describe, expect, it, beforeEach } from 'vitest'
import { pushLayer, popLayer, currentZIndexMax, resetZIndexStack } from './z-index-stack'

describe('pushLayer', () => {
  beforeEach(() => {
    resetZIndexStack()
  })

  it('allocates z-index at layer base', () => {
    expect(pushLayer('dropdown')).toBe(100)
  })

  it('increments within the same layer', () => {
    const z1 = pushLayer('modal')
    const z2 = pushLayer('modal')
    expect(z2).toBe(z1 + 1)
  })

  it('jumps to higher layer base when crossing layers', () => {
    pushLayer('modal') // 410
    const z = pushLayer('tooltip')
    expect(z).toBe(600)
  })

  it('increments above higher base when stacked', () => {
    pushLayer('tooltip') // 600
    const z = pushLayer('tooltip')
    expect(z).toBe(601)
  })

  it('reuses z-index after pop and push', () => {
    const z1 = pushLayer('modal')
    popLayer(z1)
    const z2 = pushLayer('modal')
    expect(z2).toBe(z1)
  })
})

describe('popLayer', () => {
  beforeEach(() => {
    resetZIndexStack()
  })

  it('restores previous max when popping top', () => {
    const z = pushLayer('modal') // 410
    popLayer(z)
    // stack is empty — max returns to 0
    expect(currentZIndexMax()).toBe(0)
  })

  it('restores correct previous max across layer gaps', () => {
    const z1 = pushLayer('modal')    // 410
    const z2 = pushLayer('tooltip')  // 600
    popLayer(z2)
    // should restore to 410, not 599
    expect(currentZIndexMax()).toBe(z1)
  })

  it('allows popping a non-top entry without affecting the top', () => {
    const z1 = pushLayer('modal') // 410
    pushLayer('modal') // 411
    popLayer(z1) // remove 410 from middle of stack
    expect(currentZIndexMax()).toBe(411)
  })

  it('is safe to pop unknown z-index', () => {
    popLayer(99999)
    expect(currentZIndexMax()).toBe(0)
  })
})

describe('resetZIndexStack', () => {
  it('resets to zero', () => {
    pushLayer('modal')
    resetZIndexStack()
    expect(currentZIndexMax()).toBe(0)
    expect(pushLayer('modal')).toBe(410)
  })
})
