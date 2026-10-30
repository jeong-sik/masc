import type { TabId } from '../../types'
import { navigate, replaceRoute, route } from '../../router'

type BoardTab = Extract<TabId, 'board' | 'workspace'>

interface BoardRouteTarget {
  tab: BoardTab
  params: Record<string, string>
}

export function boardRouteTarget(params: Record<string, string> = {}): BoardRouteTarget {
  if (route.value.tab === 'board') {
    return { tab: 'board', params: { ...params } }
  }
  return { tab: 'workspace', params: { section: 'board', ...params } }
}

export function navigateBoard(params: Record<string, string> = {}): void {
  const target = boardRouteTarget(params)
  navigate(target.tab, target.params)
}

export function replaceBoardRoute(params: Record<string, string> = {}): void {
  const target = boardRouteTarget(params)
  replaceRoute(target.tab, target.params)
}
