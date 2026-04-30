import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import {
  parseThemeFromHash,
  updateUrlHash,
  syncThemeAcrossSurfaces,
  THEME_STORAGE_KEY,
  THEME_HASH_PREFIX,
} from './theme-sync'
import type { ThemeId } from './use-theme'

describe('parseThemeFromHash', () => {
  it('parses dark theme from hash', () => {
    expect(parseThemeFromHash('#theme=dark')).toBe('dark')
  })

  it('parses light theme from hash', () => {
    expect(parseThemeFromHash('#theme=light')).toBe('light')
  })

  it('parses dark-fantasy theme from hash', () => {
    expect(parseThemeFromHash('#theme=dark-fantasy')).toBe('dark-fantasy')
  })

  it('parses paper theme from hash', () => {
    expect(parseThemeFromHash('#theme=paper')).toBe('paper')
  })

  it('returns null for invalid theme', () => {
    expect(parseThemeFromHash('#theme=invalid')).toBeNull()
  })

  it('returns null for unrelated hash', () => {
    expect(parseThemeFromHash('#section=1')).toBeNull()
  })
})

describe('updateUrlHash', () => {
  let originalHash: string

  beforeEach(() => {
    originalHash = location.hash
    history.replaceState(null, '', '#')
  })

  afterEach(() => {
    history.replaceState(null, '', originalHash || '#')
  })

  it('sets the theme hash', () => {
    updateUrlHash('light')
    expect(location.hash).toBe('#theme=light')
  })

  it('does nothing if hash already matches', () => {
    history.replaceState(null, '', '#theme=dark')
    const replaceSpy = vi.spyOn(history, 'replaceState')
    updateUrlHash('dark')
    expect(replaceSpy).not.toHaveBeenCalled()
    replaceSpy.mockRestore()
  })
})

describe('syncThemeAcrossSurfaces', () => {
  let cleanup: () => void

  beforeEach(() => {
    localStorage.clear()
    history.replaceState(null, '', '#')
    document.documentElement.removeAttribute('data-theme')
  })

  afterEach(() => {
    cleanup?.()
    localStorage.clear()
  })

  it('reacts to storage events for theme key', () => {
    const onStorageChange = vi.fn()
    cleanup = syncThemeAcrossSurfaces({ onStorageChange })

    window.dispatchEvent(
      new StorageEvent('storage', {
        key: THEME_STORAGE_KEY,
        newValue: 'light',
      })
    )

    expect(document.documentElement.getAttribute('data-theme')).toBe('light')
    expect(location.hash).toBe('#theme=light')
    expect(onStorageChange).toHaveBeenCalledWith('light')
  })

  it('ignores storage events for other keys', () => {
    const onStorageChange = vi.fn()
    cleanup = syncThemeAcrossSurfaces({ onStorageChange })

    window.dispatchEvent(
      new StorageEvent('storage', {
        key: 'other-key',
        newValue: 'light',
      })
    )

    expect(onStorageChange).not.toHaveBeenCalled()
  })

  it('reacts to hashchange with valid theme', () => {
    const onHashChange = vi.fn()
    cleanup = syncThemeAcrossSurfaces({ onHashChange })

    history.replaceState(null, '', '#theme=paper')
    window.dispatchEvent(new Event('hashchange'))

    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('paper')
    expect(document.documentElement.getAttribute('data-theme')).toBe('paper')
    expect(onHashChange).toHaveBeenCalledWith('paper')
  })
})
