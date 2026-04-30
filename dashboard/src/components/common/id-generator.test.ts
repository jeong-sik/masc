import { describe, expect, it } from 'vitest'
import { generateId, createARIABinding, resetIdCounter } from './id-generator'

describe('id-generator', () => {
  it('generateId returns unique ids', () => {
    resetIdCounter()
    const a = generateId()
    const b = generateId()
    expect(a).not.toBe(b)
    expect(a).toMatch(/^masc-\d+$/)
  })

  it('createARIABinding generates suffixed ids', () => {
    resetIdCounter()
    const binding = createARIABinding()
    expect(binding.id).toBe('masc-1')
    expect(binding.triggerId).toBe('masc-1-trigger')
    expect(binding.contentId).toBe('masc-1-content')
    expect(binding.titleId).toBe('masc-1-title')
    expect(binding.descriptionId).toBe('masc-1-description')
  })

  it('createARIABinding accepts custom base id', () => {
    const binding = createARIABinding('custom')
    expect(binding.id).toBe('custom')
    expect(binding.triggerId).toBe('custom-trigger')
  })

  it('resetIdCounter resets the sequence', () => {
    resetIdCounter()
    const a = generateId()
    resetIdCounter()
    const b = generateId()
    expect(a).toBe(b)
  })
})
