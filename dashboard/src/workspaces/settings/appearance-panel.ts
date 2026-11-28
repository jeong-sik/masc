/**
 * Discord-Grade Appearance Panel (embedded in `/settings` General & UI and `/account/profile`).
 *
 * - Live interactive preview card (sample chat message + tool chip + code snippet)
 * - 6 Theme options (`system` + 5 OKLCH palettes: dark, midnight, ash, light, paper-sepia)
 * - 5 OKLCH Accent swatches (`brass`, `steel`, `jade`, `rose`, `iris`)
 * - Static High-Contrast (`auto | normal | high`) & Reduce Motion (`system | on | off`)
 * - UI Scale (`85%..135%`), Chat Font (`12..20px`), Code Font (`10..18px`) sliders
 * - Density (`compact | normal | comfortable`), Chat Layout (`cozy | compact`), Chat Measure (`standard | wide`)
 * - Keeps `shell-state` `activeTheme` & `activeContrast` synchronized with `userPrefs`.
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import {
  activeContrast,
  activeTheme,
  setContrastMode,
  setThemeMode,
} from '../../shell/shell-state'
import {
  CHAT_MEASURE_MAP,
  DENSITY_SCALE_MAP,
  USER_PREFS_LIMITS,
  resetAppearancePrefs,
  resolveConcreteTheme,
  resolveEffectiveBaseTheme,
  updateUserPrefs,
  userPrefs,
  type AccentId,
  type ChatLayoutPref,
  type ChatMeasurePref,
  type ContrastPref,
  type DensityPref,
  type ReduceMotionPref,
  type ThemePreset,
} from '../../lib/user-prefs'

interface ThemeSwatchMeta {
  readonly id: ThemePreset
  readonly label: string
  readonly desc: string
  readonly bg: string
  readonly bar: string
  readonly accent: string
}

const THEME_SWATCHES: readonly ThemeSwatchMeta[] = [
  {
    id: 'system',
    label: 'System · 자동',
    desc: 'OS 색상 설정 연동',
    bg: 'linear-gradient(135deg, oklch(0.16 0.005 70) 50%, oklch(0.96 0.006 75) 50%)',
    bar: 'oklch(0.60 0.01 75)',
    accent: 'oklch(0.77 0.135 74)',
  },
  {
    id: 'dark',
    label: 'Dark · Tempered Slate',
    desc: '기본 다크 팔레트',
    bg: 'oklch(0.145 0.005 70)',
    bar: 'oklch(0.88 0.008 80)',
    accent: 'oklch(0.77 0.135 74)',
  },
  {
    id: 'midnight',
    label: 'Midnight · OLED',
    desc: '초저휘도 블랙',
    bg: 'oklch(0.070 0.004 260)',
    bar: 'oklch(0.94 0.006 250)',
    accent: 'oklch(0.74 0.125 242)',
  },
  {
    id: 'ash',
    label: 'Ash · Cool Slate',
    desc: '부드러운 쿨 슬레이트',
    bg: 'oklch(0.195 0.009 245)',
    bar: 'oklch(0.92 0.008 240)',
    accent: 'oklch(0.75 0.135 155)',
  },
  {
    id: 'light',
    label: 'Light · Warm Paper',
    desc: '아카이벌 페이퍼',
    bg: 'oklch(0.975 0.005 75)',
    bar: 'oklch(0.22 0.010 70)',
    accent: 'oklch(0.435 0.125 74)',
  },
  {
    id: 'paper-sepia',
    label: 'Paper · Sepia',
    desc: '따뜻한 양피지 톤',
    bg: 'oklch(0.955 0.020 82)',
    bar: 'oklch(0.24 0.024 62)',
    accent: 'oklch(0.47 0.145 74)',
  },
]

const ACCENT_SWATCHES: readonly {
  readonly id: AccentId
  readonly label: string
  readonly color: string
}[] = [
  { id: 'brass', label: 'Brass', color: 'oklch(0.770 0.135 74)' },
  { id: 'steel', label: 'Steel', color: 'oklch(0.740 0.125 242)' },
  { id: 'jade', label: 'Jade', color: 'oklch(0.750 0.135 155)' },
  { id: 'rose', label: 'Rose', color: 'oklch(0.735 0.145 14)' },
  { id: 'iris', label: 'Iris', color: 'oklch(0.735 0.140 292)' },
]

export function AppearancePanel(): VNode {
  const prefs = userPrefs.value
  const concreteTheme = resolveConcreteTheme(prefs.theme)

  const handleSelectTheme = (preset: ThemePreset) => {
    const next = updateUserPrefs({ theme: preset })
    const base = resolveEffectiveBaseTheme(next.theme)
    if (activeTheme.peek() !== base) {
      setThemeMode(base)
      // Re-apply preset attribute after setThemeMode so midnight/ash/paper-sepia stays intact
      updateUserPrefs({ theme: preset })
    }
  }

  const handleSelectContrast = (contrast: ContrastPref) => {
    updateUserPrefs({ contrast })
    const nextId = contrast === 'auto' ? null : contrast
    if (activeContrast.peek() !== nextId) {
      setContrastMode(nextId)
    }
  }

  const handleReset = () => {
    const next = resetAppearancePrefs()
    const base = resolveEffectiveBaseTheme(next.theme)
    setThemeMode(base)
    setContrastMode(next.contrast === 'auto' ? null : next.contrast)
    updateUserPrefs({ theme: next.theme, contrast: next.contrast })
  }

  return html`
    <section
      class="wka-card up-panel"
      data-testid="settings-appearance-panel"
      aria-label="화면 테마, 타이포그래피 및 밀도 설정"
    >
      <div class="up-header">
        <div class="up-header-meta">
          <h3 class="up-title">화면 테마 · 타이포그래피 · 밀도 (OKLCH SSOT)</h3>
          <p class="up-subtitle mono">
            preset=${prefs.theme === 'system' ? `system→${concreteTheme}` : prefs.theme}
            · accent=${prefs.accent}
            · contrast=${prefs.contrast}
            · scale=${Math.round(prefs.uiScale * 100)}%
            · density=${prefs.density}
          </p>
        </div>
        <button
          type="button"
          class="btn-ghost"
          data-testid="appearance-reset-btn"
          onClick=${handleReset}
        >
          기본값으로 초기화
        </button>
      </div>

      <!-- Live Interactive Preview Card -->
      <div
        class="up-preview-card"
        data-testid="appearance-live-preview"
        aria-label="실시간 화면 미리보기"
        style=${{
          '--ui-scale': String(prefs.uiScale),
          '--chat-font-size': `${prefs.chatFontSize}px`,
          '--code-font-size': `${prefs.codeFontSize}px`,
          '--density-scale': String(DENSITY_SCALE_MAP[prefs.density]),
          '--chat-measure': CHAT_MEASURE_MAP[prefs.chatMeasure],
        }}
      >
        <div class="up-preview-head">
          <span>실시간 미리보기 (Live Preview)</span>
          <span class="mono">
            chat ${prefs.chatFontSize}px · code ${prefs.codeFontSize}px · ${prefs.chatLayout} · ${CHAT_MEASURE_MAP[prefs.chatMeasure]}
          </span>
        </div>
        <div class="up-preview-stream" data-layout=${prefs.chatLayout}>
          <div class="up-preview-msg">
            <div class="up-preview-avatar" aria-hidden="true">K</div>
            <div class="up-preview-body">
              <div class="up-preview-author">
                <span>keeper-atlas</span>
                <span class="mono" style=${{ fontSize: 'var(--fs-10)', color: 'var(--fg-3)' }}>방금 전</span>
              </div>
              <p class="up-preview-text">
                테마 팔레트·글꼴 크기·밀도 변경이 채팅과 코드 블록에 즉시 반영됩니다.
              </p>
              <span class="up-preview-chip mono">tool: git_diff · 12ms</span>
              <pre class="up-preview-code"><code>const scale = userPrefs.value.uiScale // ${prefs.uiScale.toFixed(2)}x</code></pre>
            </div>
          </div>
        </div>
      </div>

      <!-- Theme Palettes -->
      <div class="up-section">
        <div class="up-section-title">
          <span>색상 테마 팔레트</span>
          <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>5 OKLCH + System</span>
        </div>
        <div class="up-theme-grid" role="group" aria-label="색상 테마 선택">
          ${THEME_SWATCHES.map((swatch) => {
            const active = prefs.theme === swatch.id
            return html`
              <button
                key=${swatch.id}
                type="button"
                class=${`up-theme-swatch${active ? ' is-active' : ''}`}
                data-theme-option=${swatch.id}
                aria-pressed=${active}
                onClick=${() => handleSelectTheme(swatch.id)}
              >
                <span class="up-swatch-preview" style=${{ background: swatch.bg }} aria-hidden="true">
                  <span class="up-swatch-bar" style=${{ background: swatch.bar }} />
                  <span class="up-swatch-bar up-swatch-bar--short" style=${{ background: swatch.accent }} />
                </span>
                <span class="up-swatch-label">${swatch.label}</span>
                <span class="up-swatch-desc">${swatch.desc}</span>
              </button>
            `
          })}
        </div>
      </div>

      <!-- Accent Colors -->
      <div class="up-section">
        <div class="up-section-title">
          <span>강조색 (Accent)</span>
        </div>
        <div class="up-accent-row" role="group" aria-label="강조색 선택">
          ${ACCENT_SWATCHES.map((accent) => {
            const active = prefs.accent === accent.id
            return html`
              <button
                key=${accent.id}
                type="button"
                class=${`up-accent-chip${active ? ' is-active' : ''}`}
                data-accent-option=${accent.id}
                aria-pressed=${active}
                onClick=${() => updateUserPrefs({ accent: accent.id })}
              >
                <span class="up-accent-dot" style=${{ background: accent.color }} aria-hidden="true" />
                <span>${accent.label}</span>
              </button>
            `
          })}
        </div>
      </div>

      <!-- Typography & Scale Sliders -->
      <div class="up-section">
        <div class="up-section-title">
          <span>글꼴 크기 및 UI 배율</span>
        </div>
        <div class="up-slider-list">
          <label class="up-slider-row">
            <div class="up-slider-head">
              <span>전체 UI 배율 (UI Scale)</span>
              <span class="up-slider-value" data-testid="ui-scale-value">${Math.round(prefs.uiScale * 100)}%</span>
            </div>
            <input
              type="range"
              class="up-range"
              aria-label="전체 UI 배율"
              min=${USER_PREFS_LIMITS.uiScale.min}
              max=${USER_PREFS_LIMITS.uiScale.max}
              step=${USER_PREFS_LIMITS.uiScale.step}
              value=${prefs.uiScale}
              onInput=${(e: Event) => {
                updateUserPrefs({ uiScale: Number((e.currentTarget as HTMLInputElement).value) })
              }}
            />
          </label>

          <label class="up-slider-row">
            <div class="up-slider-head">
              <span>채팅 본문 글꼴 크기 (Chat Font)</span>
              <span class="up-slider-value" data-testid="chat-font-value">${prefs.chatFontSize}px</span>
            </div>
            <input
              type="range"
              class="up-range"
              aria-label="채팅 본문 글꼴 크기"
              min=${USER_PREFS_LIMITS.chatFontSize.min}
              max=${USER_PREFS_LIMITS.chatFontSize.max}
              step=${USER_PREFS_LIMITS.chatFontSize.step}
              value=${prefs.chatFontSize}
              onInput=${(e: Event) => {
                updateUserPrefs({ chatFontSize: Number((e.currentTarget as HTMLInputElement).value) })
              }}
            />
          </label>

          <label class="up-slider-row">
            <div class="up-slider-head">
              <span>코드 블록 글꼴 크기 (Code Font)</span>
              <span class="up-slider-value" data-testid="code-font-value">${prefs.codeFontSize}px</span>
            </div>
            <input
              type="range"
              class="up-range"
              aria-label="코드 블록 글꼴 크기"
              min=${USER_PREFS_LIMITS.codeFontSize.min}
              max=${USER_PREFS_LIMITS.codeFontSize.max}
              step=${USER_PREFS_LIMITS.codeFontSize.step}
              value=${prefs.codeFontSize}
              onInput=${(e: Event) => {
                updateUserPrefs({ codeFontSize: Number((e.currentTarget as HTMLInputElement).value) })
              }}
            />
          </label>
        </div>
      </div>

      <!-- Density, Chat Layout, Measure, Contrast, Reduce Motion -->
      <div class="up-grid-2">
        <div class="up-section">
          <div class="up-section-title"><span>UI 밀도 (Density)</span></div>
          <div class="ap-viewseg" role="group" aria-label="UI 밀도 선택">
            ${(['compact', 'normal', 'comfortable'] as readonly DensityPref[]).map((d) => html`
              <button
                key=${d}
                type="button"
                class=${`ap-viewbtn ${prefs.density === d ? 'on' : ''}`}
                data-density-option=${d}
                aria-pressed=${prefs.density === d}
                onClick=${() => updateUserPrefs({ density: d })}
              >
                ${d === 'compact' ? 'Compact' : d === 'normal' ? 'Normal' : 'Comfortable'}
              </button>
            `)}
          </div>
        </div>

        <div class="up-section">
          <div class="up-section-title"><span>채팅 레이아웃 & 읽기 폭</span></div>
          <div style=${{ display: 'flex', flexWrap: 'wrap', gap: 'var(--sp-2)' }}>
            <div class="ap-viewseg" role="group" aria-label="채팅 레이아웃 선택">
              ${(['cozy', 'compact'] as readonly ChatLayoutPref[]).map((layout) => html`
                <button
                  key=${layout}
                  type="button"
                  class=${`ap-viewbtn ${prefs.chatLayout === layout ? 'on' : ''}`}
                  data-chat-layout-option=${layout}
                  aria-pressed=${prefs.chatLayout === layout}
                  onClick=${() => updateUserPrefs({ chatLayout: layout })}
                >
                  ${layout === 'cozy' ? 'Cozy' : 'Compact'}
                </button>
              `)}
            </div>
            <div class="ap-viewseg" role="group" aria-label="채팅 읽기 폭 선택">
              ${(['standard', 'wide'] as readonly ChatMeasurePref[]).map((m) => html`
                <button
                  key=${m}
                  type="button"
                  class=${`ap-viewbtn ${prefs.chatMeasure === m ? 'on' : ''}`}
                  data-chat-measure-option=${m}
                  aria-pressed=${prefs.chatMeasure === m}
                  onClick=${() => updateUserPrefs({ chatMeasure: m })}
                >
                  ${m === 'standard' ? 'Standard (78ch)' : 'Wide (110ch)'}
                </button>
              `)}
            </div>
          </div>
        </div>

        <div class="up-section">
          <div class="up-section-title"><span>고대비 모드 (APCA Lc ≥ 90)</span></div>
          <div class="ap-viewseg" role="group" aria-label="대비 모드 선택">
            <button
              type="button"
              class=${`ap-viewbtn ${prefs.contrast === 'auto' ? 'on' : ''}`}
              aria-pressed=${prefs.contrast === 'auto'}
              onClick=${() => handleSelectContrast('auto')}
            >
              시스템 자동
            </button>
            <button
              type="button"
              class=${`ap-viewbtn ${prefs.contrast === 'normal' ? 'on' : ''}`}
              aria-pressed=${prefs.contrast === 'normal'}
              onClick=${() => handleSelectContrast('normal')}
            >
              기본
            </button>
            <button
              type="button"
              class=${`ap-viewbtn ${prefs.contrast === 'high' ? 'on' : ''}`}
              aria-pressed=${prefs.contrast === 'high'}
              onClick=${() => handleSelectContrast('high')}
            >
              High Contrast
            </button>
          </div>
        </div>

        <div class="up-section">
          <div class="up-section-title"><span>모션 감소 (Reduce Motion)</span></div>
          <div class="ap-viewseg" role="group" aria-label="모션 감소 선택">
            ${(['system', 'on', 'off'] as readonly ReduceMotionPref[]).map((rm) => html`
              <button
                key=${rm}
                type="button"
                class=${`ap-viewbtn ${prefs.reduceMotion === rm ? 'on' : ''}`}
                data-reduce-motion-option=${rm}
                aria-pressed=${prefs.reduceMotion === rm}
                onClick=${() => updateUserPrefs({ reduceMotion: rm })}
              >
                ${rm === 'system' ? '시스템' : rm === 'on' ? '켜기' : '끄기'}
              </button>
            `)}
          </div>
        </div>
      </div>
    </section>
  `
}
