import { html } from 'htm/preact'
import { WorldVisualizer } from '../world-visualizer'
import { COCKPIT_FRAME_SRC, shouldLoadCockpitFrame } from './cockpit-frame'

export function Cockpit() {
  return html`
    <div class="flex h-full w-full flex-col bg-black">
      <div class="flex-none border-b border-solid border-[#333]">
        <${WorldVisualizer} />
      </div>

      ${shouldLoadCockpitFrame()
        ? html`
          <iframe
            src=${COCKPIT_FRAME_SRC}
            class="h-[calc(100vh-300px)] min-h-0 w-full flex-1 border-0"
            title="MASC Dream IDE Cockpit"
          />
        `
        : null}
    </div>
  `
}
