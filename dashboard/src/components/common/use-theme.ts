// use-theme.ts — theme context provider and consumer hook
//
// Kimi design system sec08 8.2.1: ThemeProvider + useTheme manage data-theme
// attribute, localStorage persistence, and system-preference detection.

import { createContext } from 'preact'
import { useContext, useState, useEffect, useCallback } from 'preact/hooks'
import { html } from 'htm/preact'

const THEME_STORAGE_KEY = 'masc-theme-v2'

export type ThemeId = 'dark' | 'light' | 'dark-fantasy' | 'paper'

export interface ThemeContextValue {
  theme: ThemeId
  setTheme: (t: ThemeId) => void
  systemPreference: ThemeId
}

const ThemeContext = createContext<ThemeContextValue | null>(null)

export interface ThemeProviderProps {
  children: preact.ComponentChildren
  defaultTheme?: ThemeId
}

export function ThemeProvider({ children, defaultTheme = 'dark' }: ThemeProviderProps) {
  const [theme, setThemeState] = useState<ThemeId>(() => {
    if (typeof window === 'undefined') return defaultTheme
    const stored = localStorage.getItem(THEME_STORAGE_KEY) as ThemeId | null
    return stored || defaultTheme
  })

  const [systemPreference, setSystemPreference] = useState<ThemeId>('dark')

  useEffect(() => {
    if (typeof window === 'undefined') return
    const mql = window.matchMedia('(prefers-color-scheme: light)')
    setSystemPreference(mql.matches ? 'light' : 'dark')
    const handler = (e: MediaQueryListEvent) => setSystemPreference(e.matches ? 'light' : 'dark')
    mql.addEventListener('change', handler)
    return () => mql.removeEventListener('change', handler)
  }, [])

  const setTheme = useCallback((t: ThemeId) => {
    setThemeState(t)
    if (typeof window !== 'undefined') {
      localStorage.setItem(THEME_STORAGE_KEY, t)
      document.documentElement.setAttribute('data-theme', t)
    }
  }, [])

  useEffect(() => {
    if (typeof window !== 'undefined') {
      document.documentElement.setAttribute('data-theme', theme)
    }
  }, [theme])

  return html`<${ThemeContext.Provider} value=${{ theme, setTheme, systemPreference }}>${children}</${ThemeContext.Provider}>`
}

export function useTheme(): ThemeContextValue {
  const ctx = useContext(ThemeContext)
  if (!ctx) throw new Error('useTheme must be used within ThemeProvider')
  return ctx
}
