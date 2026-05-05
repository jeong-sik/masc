import { html } from 'htm/preact'
import { WorldVisualizer } from '../world-visualizer'

export function Cockpit() {
  return html`
    <div class="flex h-full w-full flex-col bg-black">
      <div class="flex-none border-b border-solid border-[var(--color-border-default)]">
        <${WorldVisualizer} />
      </div>
    </div>
  `
}
