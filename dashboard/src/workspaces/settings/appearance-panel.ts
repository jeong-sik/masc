/**
 * Settings Appearance Panel (embedded under General & UI)
 *
 * - Clean single Dark ("Tempered Slate + Surgical Hearth") / Light ("Warm Archival Paper") toggle
 * - Static High-Contrast (`data-contrast="high"`, APCA Lc >= 90, zero runtime culori) toggle
 * - Wired directly to Layer 2's `src/lib/theme.ts`.
 */

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import {
  applyContrast,
  applyTheme,
  persistContrast,
  persistTheme,
  resolveInitialContrast,
  resolveInitialTheme,
  type ContrastId,
  type ThemeId,
} from '../../lib/theme'

export function AppearancePanel() {
  const [theme, setTheme] = useState<ThemeId>(() => resolveInitialTheme())
  const [contrast, setContrast] = useState<ContrastId | null>(() => resolveInitialContrast())

  const handleSelectTheme = (next: ThemeId) => {
    setTheme(next)
    applyTheme(next)
    persistTheme(next)
  }

  const handleSelectContrast = (next: ContrastId | null) => {
    setContrast(next)
    applyContrast(next)
    persistContrast(next)
  }

  return html`
    <section
      class="wka-card"
      data-testid="settings-appearance-panel"
      aria-label="화면 테마 및 대비 설정"
      style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', marginBottom: 'var(--sp-3)' }}
    >
      <div class="wka-h">
        <h3>화면 테마 & 고대비 (OKLCH SSOT)</h3>
        <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
          theme=${theme} · contrast=${contrast ?? 'auto'}
        </span>
      </div>

      <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))', gap: 'var(--sp-3)' }}>
        <div style=${{ display: 'flex', flexDirection: 'column', gap: '6px' }}>
          <div style=${{ fontSize: 'var(--fs-12)', fontWeight: 600, color: 'var(--fg-2)' }}>색상 테마</div>
          <div class="ap-viewseg" role="group" aria-label="색상 테마 선택">
            <button
              type="button"
              class=${`ap-viewbtn ${theme === 'dark' ? 'on' : ''}`}
              aria-pressed=${theme === 'dark'}
              onClick=${() => handleSelectTheme('dark')}
            >
              Dark · Tempered Slate
            </button>
            <button
              type="button"
              class=${`ap-viewbtn ${theme === 'light' ? 'on' : ''}`}
              aria-pressed=${theme === 'light'}
              onClick=${() => handleSelectTheme('light')}
            >
              Light · Warm Paper
            </button>
          </div>
          <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
            Tempered Slate + Surgical Hearth (Dark) / Warm Archival Paper (Light)
          </span>
        </div>

        <div style=${{ display: 'flex', flexDirection: 'column', gap: '6px' }}>
          <div style=${{ fontSize: 'var(--fs-12)', fontWeight: 600, color: 'var(--fg-2)' }}>고대비 모드 (APCA Lc ≥ 90)</div>
          <div class="ap-viewseg" role="group" aria-label="대비 모드 선택">
            <button
              type="button"
              class=${`ap-viewbtn ${contrast === null ? 'on' : ''}`}
              aria-pressed=${contrast === null}
              onClick=${() => handleSelectContrast(null)}
            >
              시스템 자동
            </button>
            <button
              type="button"
              class=${`ap-viewbtn ${contrast === 'normal' ? 'on' : ''}`}
              aria-pressed=${contrast === 'normal'}
              onClick=${() => handleSelectContrast('normal')}
            >
              기본
            </button>
            <button
              type="button"
              class=${`ap-viewbtn ${contrast === 'high' ? 'on' : ''}`}
              aria-pressed=${contrast === 'high'}
              onClick=${() => handleSelectContrast('high')}
            >
              High Contrast
            </button>
          </div>
          <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
            정적 OKLCH 프리셋 (<span class="mono">data-contrast="high"</span>) — 런타임 연산 없음
          </span>
        </div>
      </div>
    </section>
  `
}
