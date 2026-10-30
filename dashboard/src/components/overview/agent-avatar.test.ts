// @vitest-environment happy-dom
import { describe, expect, it, vi } from 'vitest'
import { render, h } from 'preact'
import { AgentAvatar } from './agent-avatar'
import { kSigil, kSlot } from '../keeper-badge'

describe('AgentAvatar', () => {
  it('renders a sigil monogram with title', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha' }), container)
    const sigil = container.querySelector('.sigil')
    expect(sigil).not.toBeNull()
    expect(sigil?.textContent).toBe(kSigil('Alpha'))
    expect(container.querySelector('.agent-avatar')?.getAttribute('title')).toBe('Alpha')
  })

  it('colors the sigil from the deterministic keeper slot', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha' }), container)
    const sigil = container.querySelector('.sigil') as HTMLElement
    expect(sigil.style.getPropertyValue('--kc')).toBe(`var(--kp${kSlot('Alpha')})`)
  })

  it('applies v2-overview-avatar marker class', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha' }), container)
    expect(container.querySelector('.v2-overview-avatar')).not.toBeNull()
  })

  it('calls onClick when clicked', () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', onClick }), container)
    const avatar = container.querySelector('.agent-avatar')
    avatar?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    expect(onClick).toHaveBeenCalled()
  })

  it('has button role and tabindex when clickable', () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', onClick }), container)
    const avatar = container.querySelector('.agent-avatar')
    expect(avatar?.getAttribute('role')).toBe('button')
    expect(avatar?.getAttribute('tabindex')).toBe('0')
  })

  it('has no button role when not clickable', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha' }), container)
    const avatar = container.querySelector('.agent-avatar')
    expect(avatar?.getAttribute('role')).toBeNull()
    expect(avatar?.getAttribute('tabindex')).toBeNull()
  })

  it('calls onClick on Enter key', () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', onClick }), container)
    const avatar = container.querySelector('.agent-avatar')
    avatar?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    expect(onClick).toHaveBeenCalled()
  })

  it('calls onClick on Space key', () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', onClick }), container)
    const avatar = container.querySelector('.agent-avatar')
    avatar?.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true }))
    expect(onClick).toHaveBeenCalled()
  })

  it('does not call onClick on other keys', () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', onClick }), container)
    const avatar = container.querySelector('.agent-avatar')
    avatar?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true }))
    expect(onClick).not.toHaveBeenCalled()
  })

  it('pulses the sigil heartbeat for active statuses', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', status: 'running' }), container)
    expect(container.querySelector('.sigil.heartbeat')).not.toBeNull()
  })

  it('does not pulse for idle status', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', status: 'idle' }), container)
    expect(container.querySelector('.sigil.heartbeat')).toBeNull()
  })

  it('maps size prop to pixel dimensions', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', size: 'sm' }), container)
    const sigil = container.querySelector('.sigil') as HTMLElement
    expect(sigil.style.width).toBe('32px')
    expect(sigil.style.height).toBe('32px')
  })

  it('supports the xs dense-list size', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', size: 'xs' }), container)
    const sigil = container.querySelector('.sigil') as HTMLElement
    expect(sigil.style.width).toBe('20px')
  })

  it('sets data-status attribute', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha', status: 'busy' }), container)
    const avatar = container.querySelector('.agent-avatar')
    expect(avatar?.getAttribute('data-status')).toBe('busy')
  })

  it('defaults data-status to idle', () => {
    const container = document.createElement('div')
    render(h(AgentAvatar, { name: 'Alpha' }), container)
    const avatar = container.querySelector('.agent-avatar')
    expect(avatar?.getAttribute('data-status')).toBe('idle')
  })
})
