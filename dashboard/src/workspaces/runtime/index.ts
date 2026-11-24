import { html } from 'htm/preact'
import { AddonsTab } from './addons-tab'
import { EfficiencyTab } from './efficiency-tab'
import { LanesTab } from './lanes-tab'
import { QuotasTab } from './quotas-tab'
import { ToolsTab } from './tools-tab'
import {
  normalizeRuntimeSubroute,
  RUNTIME_TABS,
  type RuntimeSubroute,
  type WorkspaceInspectPayload,
  type WorkspaceViewProps,
} from './types'

export {
  RUNTIME_TABS,
  normalizeRuntimeSubroute,
  type RuntimeSubroute,
  type WorkspaceInspectPayload,
  type WorkspaceViewProps,
}

export function RuntimeWorkspace(props: WorkspaceViewProps) {
  const active = normalizeRuntimeSubroute(props.subroute)

  switch (active) {
    case 'quotas':
      return html`<${QuotasTab} ...${props} />`
    case 'efficiency':
      return html`<${EfficiencyTab} ...${props} />`
    case 'lanes':
      return html`<${LanesTab} ...${props} />`
    case 'tools':
      return html`<${ToolsTab} ...${props} />`
    case 'addons':
      return html`<${AddonsTab} ...${props} />`
  }
}

export default RuntimeWorkspace
