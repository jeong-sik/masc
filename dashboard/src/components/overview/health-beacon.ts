// MASC Dashboard — Health Beacon (small status dot with label)

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

function dotColor(cls: string): string {
  if (cls === 'ok') return 'bg-[var(--ok)]'
  if (cls === 'warn') return 'bg-[var(--warn)]'
  return 'bg-[var(--bad)]'
}

function textColor(cls: string): string {
  if (cls === 'ok') return 'text-[var(--ok)]'
  if (cls === 'warn') return 'text-[var(--warn)]'
  return 'text-[var(--bad)]'
}

export function HealthBeacon({ health, label }: HealthBeaconProps) {
  const cls = healthClass(health)
  return html`
    <div class="inline-flex items-center gap-1.5 ${textColor(cls)}">
      <span class="w-2 h-2 rounded-full shrink-0 ${dotColor(cls)} health-beacon__dot" />
      <span class="text-xs font-medium">${label ?? healthLabel(health)}</span>
    </div>
  `
}
