import type { TabId } from '../types'

// --- Surface grouping: 7 tabs -> 5 surfaces ---

export type SurfaceId = 'home' | 'observe' | 'work' | 'control' | 'lab'

export interface DashboardNavGroup {
  id: SurfaceId
  label: string
  icon: string
  description: string
  defaultTab: TabId
  tabs: TabId[]
}

export interface DashboardNavItem {
  id: TabId
  label: string
  icon: string
  group: SurfaceId
  description: string
}

// 5 primary surfaces
export const DASHBOARD_SURFACES: DashboardNavGroup[] = [
  {
    id: 'home',
    label: '\uD64D',
    icon: '\uD83C\uDFE0',
    description: '\uC5D0\uC774\uC804\uD2B8 \uC0DD\uD0DC\uACC4 \uC804\uCCB4\uB97C \uD55C\uB208\uC5D0',
    defaultTab: 'home',
    tabs: ['home'],
  },
  {
    id: 'observe',
    label: '\uAD00\uCC30',
    icon: '\uD83D\uDD2D',
    description: '\uC5D0\uC774\uC804\uD2B8, \uC0C1\uD669, \uD65C\uB3D9 \uD750\uB984',
    defaultTab: 'situation',
    tabs: ['situation', 'agents', 'activity'],
  },
  {
    id: 'work',
    label: '\uC791\uC5C5',
    icon: '\uD83D\uDCCB',
    description: '\uAC8C\uC2DC\uD310, \uAC70\uBC84\uB10C\uC2A4, \uADFC\uAC70, \uACC4\uD68D',
    defaultTab: 'work',
    tabs: ['work'],
  },
  {
    id: 'control',
    label: '\uC6B4\uC601',
    icon: '\uD83C\uDFAE',
    description: '\uAC1C\uC785, \uB3C4\uAD6C \uD604\uD669',
    defaultTab: 'control',
    tabs: ['control'],
  },
  {
    id: 'lab',
    label: '\uC2E4\uD5D8',
    icon: '\u2697\uFE0F',
    description: '\uC9C0\uD718, TRPG, \uC2E4\uD5D8',
    defaultTab: 'lab',
    tabs: ['lab'],
  },
]

// Full nav item list (all 7 tabs)
export const DASHBOARD_NAV_ITEMS: DashboardNavItem[] = [
  {
    id: 'home',
    label: '\uD64D',
    icon: '\uD83C\uDFE0',
    group: 'home',
    description: '\uC5D0\uC774\uC804\uD2B8 \uC0DD\uD0DC\uACC4 \uC804\uCCB4\uB97C \uD55C\uB208\uC5D0 \uBCF4\uB294 \uAC1C\uC694',
  },
  {
    id: 'situation',
    label: '\uC0C1\uD669\uD310',
    icon: '\uD83C\uDFE0',
    group: 'observe',
    description: '\uBC29 \uC911\uC2EC\uC73C\uB85C \uC9C0\uAE08 \uC0C1\uD669\uACFC \uD750\uB984\uC744 \uAC00\uC7A5 \uBA3C\uC800 \uC77D\uB294 \uAE30\uBCF8 \uD654\uBA74',
  },
  {
    id: 'agents',
    label: '\uC5D0\uC774\uC804\uD2B8',
    icon: '\uD83D\uDC65',
    group: 'observe',
    description: '\uC5D0\uC774\uC804\uD2B8, \uD0A4\uD37C, \uC138\uC158\uC744 \uD55C\uACF3\uC5D0\uC11C \uD0D0\uC0C9',
  },
  {
    id: 'activity',
    label: '\uD65C\uB3D9',
    icon: '\uD83D\uDCE1',
    group: 'observe',
    description: '\uC2E4\uC2DC\uAC04 \uC774\uBCA4\uD2B8 \uD750\uB984\uACFC \uC18C\uC15C \uADF8\uB798\uD504',
  },
  {
    id: 'work',
    label: '\uC791\uC5C5',
    icon: '\uD83D\uDCCB',
    group: 'work',
    description: '\uAC8C\uC2DC\uD310, \uAC70\uBC84\uB10C\uC2A4, \uADFC\uAC70, \uACC4\uD68D\uC744 \uC11C\uBE0C\uC139\uC158\uC73C\uB85C \uD0D0\uC0C9',
  },
  {
    id: 'control',
    label: '\uC6B4\uC601',
    icon: '\uD83C\uDFAE',
    group: 'control',
    description: '\uB8F8/\uC138\uC158/\uD0A4\uD37C\uC5D0 \uC9C1\uC811 \uAC1C\uC785\uD558\uACE0 \uB3C4\uAD6C \uD604\uD669\uC744 \uD655\uC778',
  },
  {
    id: 'lab',
    label: '\uC2E4\uD5D8',
    icon: '\u2697\uFE0F',
    group: 'lab',
    description: '\uC9C0\uD718\uBA74, TRPG \uB4F1 \uC2E4\uD5D8 \uAE30\uB2A5',
  },
]

// Legacy compatibility: old section types used by SideRail
export type DashboardNavGroupLegacy = 'now' | 'why' | 'act' | 'lab'

export interface DashboardNavSection {
  id: DashboardNavGroupLegacy
  label: string
  description: string
}

// Kept for backward compat — unused in the new nav but referenced by semantic-layer
export const DASHBOARD_NAV_SECTIONS: DashboardNavSection[] = [
  { id: 'now', label: '\uC9C0\uAE08', description: '\uD604\uC7AC \uC0C1\uD0DC' },
  { id: 'why', label: '\uC774\uC720', description: '\uADFC\uAC70\uC640 \uB9E5\uB77D' },
  { id: 'act', label: '\uAC1C\uC785', description: '\uC6B4\uC601 \uC561\uC158' },
  { id: 'lab', label: '\uC2E4\uD5D8', description: '\uC2E4\uD5D8 \uD654\uBA74' },
]

// Surface lookup by tab id
export function surfaceForTab(tabId: TabId): SurfaceId {
  for (const surface of DASHBOARD_SURFACES) {
    if (surface.tabs.includes(tabId)) return surface.id
  }
  return 'home'
}
