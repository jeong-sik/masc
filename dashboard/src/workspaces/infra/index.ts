import { html } from 'htm/preact'
import { LogsTab } from './logs-tab'
import { ReposTab } from './repos-tab'
import { SandboxesTab } from './sandboxes-tab'
import {
  INFRA_TABS,
  normalizeInfraSubroute,
  type InfraSubroute,
  type WorkspaceInspectPayload,
  type WorkspaceViewProps,
} from './types'

export {
  INFRA_TABS,
  normalizeInfraSubroute,
  type InfraSubroute,
  type WorkspaceInspectPayload,
  type WorkspaceViewProps,
}

export function InfraWorkspace(props: WorkspaceViewProps) {
  const active = normalizeInfraSubroute(props.subroute)

  switch (active) {
    case 'sandboxes':
      return html`<${SandboxesTab} ...${props} />`
    case 'repos':
      return html`<${ReposTab} ...${props} />`
    case 'logs':
      return html`<${LogsTab} ...${props} />`
  }
}

export default InfraWorkspace
