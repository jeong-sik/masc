// MobileBottomBar — 하단 고정 주요 서피스 탭 + ☰(전체 drawer 진입).
//
// 모바일(<=768px)에서만 렌더. 엄지 도달 영역(하단)에 사용자 우선순위가 높은
// 4개 서피스(overview·monitoring·command·workspace)를 노출해 한 손으로 빠른
// 상태 파악·턴 제어 진입을 보장. 나머지 서피스(connectors·lab·code·logs)는
// ☰ 버튼이 여는 overlay drawer(app.ts 의 mobileMenuOpen)로 접근.
//
// 터치 타겟: 각 항목 min-h-[44px] (Apple HIG / WCAG 2.5.5 권장 최소).
// RouteLink 가 ring focus 를 자동 추가하므로 class 에 ring 을 넣지 않는다.

import { html } from 'htm/preact'
import { Menu } from 'lucide-preact'
import { RouteLink } from './common/route-link'
import { SurfaceIcon } from './surface-icon'
import { VISIBLE_DASHBOARD_NAV_ITEMS } from '../config/navigation'
import { ringFocusClasses } from './common/ring'
import type { TabId } from '../types'

// 하단 탭에 노출할 주요 서피스. 선택 기준 = 사용자 모바일 우선순위
// (턴·폴링 제어 = command, 상태 모니터링 = monitoring/overview,
//  작업 보드 = workspace). 이 4개는 모바일에서 80% 이상의 진입을 커버.
const MOBILE_PRIMARY_TAB_IDS: ReadonlyArray<TabId> = [
  'overview',
  'monitoring',
  'command',
  'workspace',
]

const mobilePrimaryItems = VISIBLE_DASHBOARD_NAV_ITEMS.filter(item =>
  MOBILE_PRIMARY_TAB_IDS.includes(item.id),
)

interface MobileBottomBarProps {
  currentTab: TabId
  onMenuToggle: () => void
}

export function MobileBottomBar({ currentTab, onMenuToggle }: MobileBottomBarProps) {
  return html`
    <nav
      class="v2-shell-surface hidden max-[768px]:flex fixed inset-x-0 bottom-0 z-40 items-stretch border-t border-[var(--color-border-strong)] bg-[var(--shell-header-bg)] backdrop-blur-xl"
      style=${{ paddingBottom: 'env(safe-area-inset-bottom, 0px)' }}
      aria-label="Primary mobile navigation"
    >
      ${mobilePrimaryItems.map(item => {
        const active = item.id === currentTab
        return html`
          <${RouteLink}
            tab=${item.id}
            params=${item.defaultParams}
            ariaCurrent=${active ? 'page' : undefined}
            'aria-label'=${item.label}
            class=${`flex min-h-[44px] flex-1 flex-col items-center justify-center gap-0.5 px-1 transition-colors ${
              active
                ? 'text-[var(--select)]'
                : 'text-[var(--color-fg-muted)] hover:text-[var(--color-fg-secondary)]'
            }`}
          >
            <${SurfaceIcon} icon=${item.icon} size=${20} />
            <span class="font-mono text-3xs uppercase leading-none tracking-[var(--track-caps)]">${item.label}</span>
          <//>
        `
      })}
      <button
        type="button"
        'aria-label'="Open full navigation"
        class=${`v2-shell-action flex min-h-[44px] flex-col items-center justify-center gap-0.5 px-3 text-[var(--color-fg-muted)] cursor-pointer transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-secondary)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'page' })}`}
        onClick=${onMenuToggle}
      >
        <${Menu} size=${20} />
        <span class="font-mono text-3xs uppercase leading-none tracking-[var(--track-caps)]">More</span>
      </button>
    </nav>
  `
}
