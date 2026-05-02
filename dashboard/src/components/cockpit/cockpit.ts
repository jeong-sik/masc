import { html } from 'htm/preact'
import { WorldVisualizer } from '../world-visualizer'
import { COCKPIT_FRAME_SRC, shouldLoadCockpitFrame } from './cockpit-frame'

export function Cockpit() {
  return html`
    <div style=${{ display: 'flex', flexDirection: 'column', height: '100%', width: '100%', backgroundColor: '#000' }}>
      <div style=${{ flex: '0 0 auto', borderBottom: '1px solid #333' }}>
        <${WorldVisualizer} />
      </div>

      ${shouldLoadCockpitFrame()
        ? html`
          <iframe
            src=${COCKPIT_FRAME_SRC}
            style=${{ flex: 1, border: 'none', width: '100%', height: 'calc(100vh - 300px)' }}
            title="MASC Dream IDE Cockpit"
          />
        `
        : null}
    </div>
  `
}
