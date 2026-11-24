// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { h, render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { KeeperBadge, kSlot, kSigil, keeperPortraitUrl } from './keeper-badge'

describe('kSlot', () => {
  it('returns deterministic slot 1..12 for unknown ids', () => {
    const slot = kSlot('unknown-keeper-7')
    expect(slot).toBeGreaterThanOrEqual(1)
    expect(slot).toBeLessThanOrEqual(12)
    expect(kSlot('unknown-keeper-7')).toBe(slot)
  })

  it('distributes 100 random ids across at least 8 of 12 slots', () => {
    const seen = new Set<number>()
    for (let i = 0; i < 100; i++) seen.add(kSlot(`id-${i}`))
    expect(seen.size).toBeGreaterThanOrEqual(8)
  })
})

describe('kSigil', () => {
  it('extracts first + last segment initials for hyphenated ids without family collisions', () => {
    expect(kSigil('foo-bar')).toBe('FB')
    expect(kSigil('code-reviewer-sister')).toBe('CS')
    expect(kSigil('code-reviewer-brother')).toBe('CB')
    expect(kSigil('code-reviewer-father')).toBe('CF')
    expect(kSigil('code-reviewer-uncle')).toBe('CU')
    expect(kSigil('e-masc-the-leader')).toBe('EL')
    expect(kSigil('e-masc-the-scribe')).toBe('ES')
    expect(kSigil('alpha-beta-gamma')).toBe('AG')
  })

  it('falls back to first 2 letters for non-hyphenated ids', () => {
    expect(kSigil('agentcode')).toBe('AG')
    expect(kSigil('providerf')).toBe('PR')
  })

  it('uppercases lowercase ids', () => {
    expect(kSigil('alice')).toBe('AL')
  })

  it('strips non-alphanumeric chars before deriving', () => {
    expect(kSigil('ab.cd')).toBe('AB')
    expect(kSigil('foo!bar')).toBe('FO')
  })
})

describe('KeeperBadge', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders a soft-tinted chip with collision-free sigil and slot class', () => {
    render(h(KeeperBadge, { id: 'code-reviewer-sister' }), container)
    const chip = container.querySelector('.kb-chip')
    expect(chip).not.toBeNull()
    expect(chip?.classList.contains(`kb-slot-${kSlot('code-reviewer-sister')}`)).toBe(true)
    expect(container.querySelector('.kb-sigil')?.textContent).toBe('CS')
    expect(container.querySelector('.kb-label')?.textContent).toBe('code-reviewer-sister')
  })

  it('renders portrait thumbnail and falls back cleanly to sigil on image error', () => {
    render(h(KeeperBadge, { id: 'e-masc-the-leader', portrait: true, size: 'lg' }), container)
    const img = container.querySelector('img.kb-portrait') as HTMLImageElement | null
    expect(img).not.toBeNull()
    expect(img?.getAttribute('src')).toBe(keeperPortraitUrl('e-masc-the-leader', 64))

    fireEvent.error(img!)
    expect(container.querySelector('img.kb-portrait')).toBeNull()
    expect(container.querySelector('.kb-sigil')?.textContent).toBe('EL')
  })
})
