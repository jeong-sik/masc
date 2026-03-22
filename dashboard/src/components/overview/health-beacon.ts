// MASC Dashboard — Health Beacon (room health pulsing indicator)

import { html } from 'htm/preact'

interface HealthBeaconProps {
  health?: string | null
  label?: string
}

function healthClass(health: string | null | undefined): string {
  if (!health) return 'warn'
  const h = health.toLowerCase()
  if (h === 'healthy' || h === 'ok' || h === 'green') return 'ok'
  if (h === 'degraded' || h === 'warn' || h === 'yellow' || h === 'watch') return 'warn'
  return 'bad'
}

function healthLabel(health: string | null | undefined): string {
  if (!health) return '확인 중'
  const h = health.toLowerCase()
  if (h === 'healthy' || h === 'ok' || h === 'green') return '정상'
  if (h === 'degraded' || h === 'warn' || h === 'yellow' || h === 'watch') return '주의'
  return '위험'
}

export function HealthBeacon({ health, label }: HealthBeaconProps) {
  const cls = healthClass(health)
  return html`
    <div class="health-beacon inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-sm font-medium ${cls}">
      <span class="health-beacon__dot w-2 h-2 rounded-full shrink-0" />
      <span>${label ?? healthLabel(health)}</span>
    </div>
  `
}
