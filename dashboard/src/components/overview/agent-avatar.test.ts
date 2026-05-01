// @vitest-environment happy-dom
import { describe, expect, it, vi } from 'vitest'
import { render, h } from 'preact'
import { AgentAvatar } from './agent-avatar'

vi.mock('../../config/avatar-palettes', () => ({
  paletteForAgent: () => ({ skin: '#f5c89a', hair: '#7a4e3a', point: '#e8917a', highlight: '#f5c542' }),
  templateForAgent: () => 'humanoid',
  PIXEL_TEMPLATES: {
    humanoid: [
      0, 0, 2, 2, 2, 2, 0, 0,
      0, 2, 2, 2, 2, 2, 2, 0,
      0, 2, 1, 3, 3, 1, 2, 0,
      0, 0, 1, 1, 1, 1, 0, 0,
      0, 0, 1, 4, 4, 1, 0, 0,
      0, 3, 3, 1, 1, 3, 3, 0,
      0, 0, 1, 1, 1, 1, 0, 0,
      0, 0, 1, 0, 0, 1, 0, 0,
    ],
  },
}))

describe('AgentAvatar', () => {
  it('renders pixel avatar with title', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha' }), container)
    const avatar = container.querySelector('.pixel-avatar')
    expect(avatar).not.toBeNull()
    expect(avatar?.getAttribute('title')).toBe('Alpha')
  })

  it('shows name when showName is true', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', showName: true }), container)
    expect(container.textContent).toContain('Alpha')
  })

  it('does not show name when showName is false', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', showName: false }), container)
    expect(container.textContent).not.toContain('Alpha')
  })

  it('calls onClick when clicked', () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', onClick }), container)
    const avatar = container.querySelector('.pixel-avatar')
    avatar?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    expect(onClick).toHaveBeenCalled()
  })

  it('has button role and tabindex when clickable', () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', onClick }), container)
    const avatar = container.querySelector('.pixel-avatar')
    expect(avatar?.getAttribute('role')).toBe('button')
    expect(avatar?.getAttribute('tabindex')).toBe('0')
  })

  it('has no button role when not clickable', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha' }), container)
    const avatar = container.querySelector('.pixel-avatar')
    expect(avatar?.getAttribute('role')).toBeNull()
    expect(avatar?.getAttribute('tabindex')).toBeNull()
  })

  it('calls onClick on Enter key', () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', onClick }), container)
    const avatar = container.querySelector('.pixel-avatar')
    avatar?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    expect(onClick).toHaveBeenCalled()
  })

  it('calls onClick on Space key', () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', onClick }), container)
    const avatar = container.querySelector('.pixel-avatar')
    avatar?.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true }))
    expect(onClick).toHaveBeenCalled()
  })

  it('does not call onClick on other keys', () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', onClick }), container)
    const avatar = container.querySelector('.pixel-avatar')
    avatar?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true }))
    expect(onClick).not.toHaveBeenCalled()
  })

  it('shows activity dot with live-pulse for recent activity', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', activityAge: 30 }), container)
    const dot = container.querySelector('.activity-dot--live-pulse')
    expect(dot).not.toBeNull()
  })

  it('shows activity dot with stale for older activity', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', activityAge: 600 }), container)
    const dot = container.querySelector('.activity-dot--stale')
    expect(dot).not.toBeNull()
  })

  it('shows activity dot with inactive for very old activity', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', activityAge: 3600 }), container)
    const dot = container.querySelector('.activity-dot--inactive')
    expect(dot).not.toBeNull()
  })

  it('shows activity dot with unknown when no age', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', activityAge: null }), container)
    const dot = container.querySelector('.activity-dot--unknown')
    expect(dot).not.toBeNull()
  })

  it('shows speech bubble with truncated currentWork', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', currentWork: 'Working on something important' }), container)
    expect(container.textContent).toContain('Working on')
  })

  it('does not show speech bubble when currentWork is empty', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', currentWork: '' }), container)
    expect(container.querySelector('.pixel-avatar__speech-bubble')).toBeNull()
  })

  it('applies blocker class when hasBlocker is true', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', hasBlocker: true }), container)
    const avatar = container.querySelector('.pixel-avatar--has-blocker')
    expect(avatar).not.toBeNull()
  })

  it('applies signal ring class for live truth', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', signalTruth: 'live' }), container)
    const avatar = container.querySelector('.signal-ring--live')
    expect(avatar).not.toBeNull()
  })

  it('applies signal ring class for stale truth', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', signalTruth: 'stale' }), container)
    const avatar = container.querySelector('.signal-ring--stale')
    expect(avatar).not.toBeNull()
  })

  it('applies signal ring class for archived truth', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', signalTruth: 'archived' }), container)
    const avatar = container.querySelector('.signal-ring--archived')
    expect(avatar).not.toBeNull()
  })

  it('applies size class when size prop provided', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', size: 'sm' }), container)
    const avatar = container.querySelector('.pixel-avatar--sm')
    expect(avatar).not.toBeNull()
  })

  it('renders 64 pixel cells', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha' }), container)
    const cells = container.querySelectorAll('.pixel-avatar__cell')
    expect(cells.length).toBe(64)
  })

  it('sets data-status attribute', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', status: 'busy' }), container)
    const avatar = container.querySelector('.pixel-avatar')
    expect(avatar?.getAttribute('data-status')).toBe('busy')
  })

  it('defaults data-status to idle', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha' }), container)
    const avatar = container.querySelector('.pixel-avatar')
    expect(avatar?.getAttribute('data-status')).toBe('idle')
  })

  it('truncates long currentWork text', () => {
    const container = document.createElement('div')
    const longWork = 'a'.repeat(50)
    render(h(AgentAvatar, { name: 'Alpha', currentWork: longWork }), container)
    const bubble = container.querySelector('.pixel-avatar__speech-bubble')
    expect(bubble?.textContent?.length).toBeLessThanOrEqual(21)
    expect(bubble?.textContent?.endsWith('…')).toBe(true)
  })
})
