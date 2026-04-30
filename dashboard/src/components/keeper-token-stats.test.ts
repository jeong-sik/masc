// @vitest-environment happy-dom
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, h } from 'preact'

const mockKeepers = vi.hoisted(() => vi.fn(() => []))
const mockSelectedKeeperFilter = vi.hoisted(() => vi.fn(() => new Set<string>()))

vi.mock('@preact/signals', async () => {
  const actual = await vi.importActual('@preact/signals') as any
  return {
    ...actual,
    computed: (fn: any) => ({
      get value() { return fn() },
      peek() { return fn() },
    }),
  }
})

vi.mock('../store', () => ({
  keepers: { get value() { return mockKeepers() } },
  selectedKeeperFilter: { get value() { return mockSelectedKeeperFilter() } },
  toggleKeeperInFilter: vi.fn(),
  clearKeeperFilter: vi.fn(),
  setKeeperFilterToAll: vi.fn(),
}))

import { KeeperTokenStats } from './keeper-token-stats'

describe('KeeperTokenStats', () => {
  beforeEach(() => {
    mockKeepers.mockReturnValue([])
    mockSelectedKeeperFilter.mockReturnValue(new Set<string>())
  })

  it('shows empty message when no keepers', () => {
    const container = document.createElement('div')
    render(h(KeeperTokenStats), container)
    expect(container.textContent).toContain('아직 토큰을 소비한 키퍼가 없습니다')
  })

  it('shows empty message when keepers have zero tokens and turns', () => {
    mockKeepers.mockReturnValue([
      { name: 'Alpha', koreanName: '알파', emoji: '🐱', total_tokens: 0, total_turns: 0, turn_count: 0 },
    ])
    const container = document.createElement('div')
    render(h(KeeperTokenStats), container)
    expect(container.textContent).toContain('아직 토큰을 소비한 키퍼가 없습니다')
  })

  it('renders table with keeper data sorted by tokens desc', () => {
    mockKeepers.mockReturnValue([
      { name: 'Beta', koreanName: '베타', emoji: '🐶', total_tokens: 500, total_turns: 10, turn_count: 10 },
      { name: 'Alpha', koreanName: '알파', emoji: '🐱', total_tokens: 1000, total_turns: 20, turn_count: 20 },
    ])
    const container = document.createElement('div')
    render(h(KeeperTokenStats), container)
    const rows = container.querySelectorAll('tbody tr')
    expect(rows.length).toBe(2)
    expect(rows[0]!.textContent).toContain('알파')
    expect(rows[1]!.textContent).toContain('베타')
    expect(container.textContent).toContain('1,000')
    expect(container.textContent).toContain('500')
  })

  it('filters by selectedKeeperFilter', () => {
    mockKeepers.mockReturnValue([
      { name: 'Alpha', koreanName: '알파', emoji: '🐱', total_tokens: 100, total_turns: 5, turn_count: 5 },
      { name: 'Beta', koreanName: '베타', emoji: '🐶', total_tokens: 200, total_turns: 10, turn_count: 10 },
    ])
    mockSelectedKeeperFilter.mockReturnValue(new Set(['Alpha']))
    const container = document.createElement('div')
    render(h(KeeperTokenStats), container)
    const rows = container.querySelectorAll('tbody tr')
    expect(rows.length).toBe(1)
    expect(rows[0]!.textContent).toContain('알파')
    expect(rows[0]!.textContent).not.toContain('베타')
  })

  it('falls back to name when koreanName missing', () => {
    mockKeepers.mockReturnValue([
      { name: 'Gamma', total_tokens: 100, total_turns: 3, turn_count: 3 },
    ])
    const container = document.createElement('div')
    render(h(KeeperTokenStats), container)
    expect(container.textContent).toContain('Gamma')
  })

  it('shows totals in footer', () => {
    mockKeepers.mockReturnValue([
      { name: 'Alpha', koreanName: '알파', emoji: '🐱', total_tokens: 100, total_turns: 5, turn_count: 5 },
      { name: 'Beta', koreanName: '베타', emoji: '🐶', total_tokens: 200, total_turns: 10, turn_count: 10 },
    ])
    const container = document.createElement('div')
    render(h(KeeperTokenStats), container)
    expect(container.textContent).toContain('300')
    expect(container.textContent).toContain('15')
    expect(container.textContent).toContain('2 keepers')
  })

  it('renders distribution bars with relative widths', () => {
    mockKeepers.mockReturnValue([
      { name: 'Alpha', koreanName: '알파', emoji: '🐱', total_tokens: 500, total_turns: 5, turn_count: 5 },
      { name: 'Beta', koreanName: '베타', emoji: '🐶', total_tokens: 250, total_turns: 10, turn_count: 10 },
    ])
    const container = document.createElement('div')
    render(h(KeeperTokenStats), container)
    const bars = container.querySelectorAll('tbody td:last-child div div')
    expect(bars.length).toBe(2)
    expect(bars[0]!.getAttribute('style')).toContain('width: 100.0%')
    expect(bars[1]!.getAttribute('style')).toContain('width: 50.0%')
  })

  it('uses turn_count fallback when total_turns missing', () => {
    mockKeepers.mockReturnValue([
      { name: 'Alpha', koreanName: '알파', emoji: '🐱', total_tokens: 50, turn_count: 7 },
    ])
    const container = document.createElement('div')
    render(h(KeeperTokenStats), container)
    expect(container.textContent).toContain('7')
  })
})
