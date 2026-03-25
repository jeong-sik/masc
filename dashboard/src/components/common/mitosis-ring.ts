import { html } from 'htm/preact'

export function MitosisRing({ ratio, size = 40, stroke = 4 }: { ratio?: number; size?: number; stroke?: number }) {
  if (ratio == null) return null
  const r = (size - stroke) / 2
  const c = size / 2
  const dasharray = 2 * Math.PI * r
  const dashoffset = dasharray * ((100 - ratio * 100) / 100)
  
  // Color based on ratio
  let colorClass = 'mitosis-safe'
  if (ratio >= 0.8) colorClass = 'mitosis-critical'
  else if (ratio >= 0.5) colorClass = 'mitosis-warn'

  return html`
    <div class="relative inline-flex items-center justify-center ml-auto mr-2.5" title="분열 컨텍스트 부하: ${Math.round(ratio * 100)}%">
      <svg class="mitosis-ring" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
        <circle class="mitosis-ring-bg" cx="${c}" cy="${c}" r="${r}" stroke-width="${stroke}" />
        <circle 
          class="mitosis-ring-fg ${colorClass}" 
          cx="${c}" cy="${c}" r="${r}" 
          stroke-width="${stroke}" 
          stroke-dasharray="${dasharray}" 
          stroke-dashoffset="${dashoffset}" 
        />
      </svg>
      <span class="absolute text-[0.65rem] font-bold ${colorClass}">${Math.round(ratio * 100)}%</span>
    </div>
  `
}
