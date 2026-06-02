// Shared HTML escape utilities for vis-network/vis-timeline tooltips

export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

export function tooltipHtml(lines: string[]): string {
  return lines.map(escapeHtml).join('<br/>')
}
