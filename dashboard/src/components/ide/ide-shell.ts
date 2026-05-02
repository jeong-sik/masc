import { html } from 'htm/preact'
import { WorldVisualizer } from '../world-visualizer'

export function IdeShell() {
  return html`
    <section class="ide-plane-shell" style=${{ display: 'flex', flexDirection: 'column', height: 'calc(100vh - var(--h-topnav) - var(--h-kpi))', width: '100%', backgroundColor: '#000' }}>
      <!-- 7 Physical Laws Canvas rendering the Stigmergy traces -->
      <div style=${{ flex: '0 0 auto', borderBottom: '1px solid #333' }}>
         <${WorldVisualizer} />
      </div>
      
      <!-- The High-Fidelity UI Mockup ported from the user downloads -->
      <iframe 
        src="/cockpit/MASC Cockpit (Full).html" 
        style=${{ flex: 1, border: 'none', width: '100%', height: '100%' }} 
        title="MASC Dream IDE Cockpit"
      />
    </section>
  `
}
