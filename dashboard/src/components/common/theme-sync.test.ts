import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import {
  parseThemeFromSearch,
  updateThemeSearchParam,
  syncThemeAcrossSurfaces,
  THEME_STORAGE_KEY,
  THEME_SEARCH_PARAM,
} from './theme-sync'

describe('parseThemeFromSearch', () => {
  it('parses dark theme from search string', () => {
    expect(parseThemeFromSearch('?theme=dark')).toBe('dark')
  })

  it('parses light theme from search string', () => {
    expect(parseThemeFromSearch('?theme=light')).toBe('light')
  })

  it('parses without leading ?', () => {
    expect(parseThemeFromSearch('theme=paper')).toBe('paper')
  })

  it('returns null for invalid theme', () => {
    expect(parseThemeFromSearch('?theme=invalid')).toBeNull()
  })

  it('returns null when param is absent', () => {
    expect(parseThemeFromSearch('?section=1')).toBeNull()
  })
})

describe('updateThemeSearchParam', () => {
  let originalSearch: string

  beforeEach(() => {
    originalSearch = location.search
    history.replaceState(null, '', '/')
  })

  afterEach(() => {
    history.replaceState(null, '', `/${originalSearch}`)
  })

  it('sets the theme search param', () => {
    updateThemeSearchParam('light')
    expect(new URLSearchParams(location.search).get(THEME_SEARCH_PARAM)).toBe('light')
  })

  it('does nothing if search param already matches', () => {
    history.replaceState(null, '', '/?theme=dark')
    const replaceSpy = vi.spyOn(history, 'replaceState')
    updateThemeSearchParam('dark')
    expect(replaceSpy).not.toHaveBeenCalled()
    replaceSpy.mockRestore()
  })

  it('does not modify location.hash', () => {
    history.replaceState(null, '', '/#overview')
    updateThemeSearchParam('light')
    expect(location.hash).toBe('#overview')
  })
})

describe('syncThemeAcrossSurfaces', () => {
  let cleanup: () => void

  beforeEach(() => {
    localStorage.clear()
    history.replaceState(null, '', '/')
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
    expect(new URLSearchParams(location.search).get(THEME_SEARCH_PARAM)).toBe('light')
    expect(onStorageChange).toHaveBeenCalledWith('light')
  })

  it('does not overwrite location.hash on storage change', () => {
    history.replaceState(null, '', '/#command?section=intervene')
    cleanup = syncThemeAcrossSurfaces({})

    window.dispatchEvent(
      new StorageEvent('storage', {
        key: THEME_STORAGE_KEY,
        newValue: 'dark',
      })
    )

    expect(location.hash).toBe('#command?section=intervene')
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

  it('reacts to popstate with valid theme in search params', () => {
    const onSearchChange = vi.fn()
    cleanup = syncThemeAcrossSurfaces({ onSearchChange })

    history.replaceState(null, '', '/?theme=paper')
    window.dispatchEvent(new PopStateEvent('popstate'))

    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('paper')
    expect(document.documentElement.getAttribute('data-theme')).toBe('paper')
    expect(onSearchChange).toHaveBeenCalledWith('paper')
  })
})
