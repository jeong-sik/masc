// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import {
  normalizeKey,
  isKey,
  KeyMatcher,
  createKeyHandler,
} from './key-handler'

describe('key-handler', () => {
  describe('normalizeKey', () => {
    it('normalizes Enter', () => {
      expect(normalizeKey('Enter')).toBe('Enter')
    })

    it('normalizes space variants', () => {
      expect(normalizeKey(' ')).toBe('Space')
      expect(normalizeKey('Spacebar')).toBe('Space')
    })

    it('normalizes Escape variants', () => {
      expect(normalizeKey('Escape')).toBe('Escape')
      expect(normalizeKey('Esc')).toBe('Escape')
    })

    it('normalizes arrow keys', () => {
      expect(normalizeKey('ArrowUp')).toBe('ArrowUp')
      expect(normalizeKey('ArrowDown')).toBe('ArrowDown')
      expect(normalizeKey('ArrowLeft')).toBe('ArrowLeft')
      expect(normalizeKey('ArrowRight')).toBe('ArrowRight')
    })

    it('returns undefined for unknown keys', () => {
      expect(normalizeKey('Foo')).toBeUndefined()
    })
  })

  describe('isKey', () => {
    it('matches normalized keys', () => {
      expect(isKey({ key: 'Enter' }, 'Enter')).toBe(true)
      expect(isKey({ key: ' ' }, 'Space')).toBe(true)
      expect(isKey({ key: 'Escape' }, 'Escape')).toBe(true)
    })

    it('rejects non-matching keys', () => {
      expect(isKey({ key: 'Enter' }, 'Space')).toBe(false)
    })
  })

  describe('KeyMatcher', () => {
    it('matches Enter and Space', () => {
      expect(KeyMatcher.isEnter({ key: 'Enter' })).toBe(true)
      expect(KeyMatcher.isSpace({ key: ' ' })).toBe(true)
    })

    it('matches Escape', () => {
      expect(KeyMatcher.isEscape({ key: 'Escape' })).toBe(true)
      expect(KeyMatcher.isEscape({ key: 'Esc' })).toBe(true)
    })

    it('matches arrows', () => {
      expect(KeyMatcher.isArrowUp({ key: 'ArrowUp' })).toBe(true)
      expect(KeyMatcher.isArrowDown({ key: 'ArrowDown' })).toBe(true)
      expect(KeyMatcher.isArrowLeft({ key: 'ArrowLeft' })).toBe(true)
      expect(KeyMatcher.isArrowRight({ key: 'ArrowRight' })).toBe(true)
    })

    it('matches Home, End, Tab, Backspace, Delete', () => {
      expect(KeyMatcher.isHome({ key: 'Home' })).toBe(true)
      expect(KeyMatcher.isEnd({ key: 'End' })).toBe(true)
      expect(KeyMatcher.isTab({ key: 'Tab' })).toBe(true)
      expect(KeyMatcher.isBackspace({ key: 'Backspace' })).toBe(true)
      expect(KeyMatcher.isDelete({ key: 'Delete' })).toBe(true)
      expect(KeyMatcher.isDelete({ key: 'Del' })).toBe(true)
    })
  })

  describe('createKeyHandler', () => {
    it('dispatches to the correct handler', () => {
      const onEnter = vi.fn()
      const onEscape = vi.fn()
      const handler = createKeyHandler({ onEnter, onEscape })

      handler(new KeyboardEvent('keydown', { key: 'Enter' }))
      expect(onEnter).toHaveBeenCalledTimes(1)
      expect(onEscape).not.toHaveBeenCalled()

      handler(new KeyboardEvent('keydown', { key: 'Escape' }))
      expect(onEscape).toHaveBeenCalledTimes(1)
    })

    it('ignores unmapped keys', () => {
      const onEnter = vi.fn()
      const handler = createKeyHandler({ onEnter })
      handler(new KeyboardEvent('keydown', { key: 'Shift' }))
      expect(onEnter).not.toHaveBeenCalled()
    })

    it('passes the event to the handler', () => {
      const onSpace = vi.fn()
      const handler = createKeyHandler({ onSpace })
      const ev = new KeyboardEvent('keydown', { key: ' ' })
      handler(ev)
      expect(onSpace).toHaveBeenCalledWith(ev)
    })
  })
})
