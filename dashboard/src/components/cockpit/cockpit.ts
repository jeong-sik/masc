import { html } from 'htm/preact'
import { WorldVisualizer } from '../world-visualizer'

export function Cockpit() {
  return html`
    <div style=${{ display: 'flex', flexDirection: 'column', height: '100%', width: '100%', backgroundColor: '#000' }}>
      <!-- 7 Physical Laws Canvas rendering the Stigmergy traces -->
      <div style=${{ flex: '0 0 auto', borderBottom: '1px solid #333' }}>
         <${WorldVisualizer} />
      </div>
      
      <!-- The High-Fidelity UI Mockup ported from the user downloads -->
      <iframe 
        src="/cockpit/MASC Cockpit (Full).html" 
        style=${{ flex: 1, border: 'none', width: '100%', height: 'calc(100vh - 300px)' }} 
        title="MASC Dream IDE Cockpit"
      />
    </div>
  `
}
