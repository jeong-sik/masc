import { html } from 'htm/preact'
import {
  Activity,
  ClipboardList,
  Code2,
  FlaskConical,
  Gauge,
  Home,
  Plug,
  ScrollText,
} from 'lucide-preact'
import type { DashboardSurfaceIcon } from '../config/navigation'

interface SurfaceIconProps {
  icon: DashboardSurfaceIcon
  size?: number
}

export function SurfaceIcon({ icon, size = 16 }: SurfaceIconProps) {
  const props = { size, strokeWidth: 1.8, 'aria-hidden': true }
  switch (icon) {
    case 'overview':
      return html`<${Home} ...${props} />`
    case 'monitoring':
      return html`<${Activity} ...${props} />`
    case 'command':
      return html`<${Gauge} ...${props} />`
    case 'connectors':
      return html`<${Plug} ...${props} />`
    case 'workspace':
      return html`<${ClipboardList} ...${props} />`
    case 'lab':
      return html`<${FlaskConical} ...${props} />`
    case 'code':
      return html`<${Code2} ...${props} />`
    case 'logs':
      return html`<${ScrollText} ...${props} />`
  }
}
