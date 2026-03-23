import { html } from 'htm/preact'
import { EmptyState } from '../common/empty-state'
import {
  commandPlaneDetailError,
  commandPlaneDetailLoading,
} from '../../command-store'

export function DetailLoadingState() {
  if (commandPlaneDetailLoading.value) {
    return html`<${EmptyState} message="command-plane detail 불러오는 중…" compact />`
  }
  if (commandPlaneDetailError.value) {
    return html`<${EmptyState} message=${commandPlaneDetailError.value} compact />`
  }
  return html`<${EmptyState} message="surface를 선택하면 command-plane detail을 로드합니다." compact />`
}
