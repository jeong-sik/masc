import { html } from 'htm/preact'
import { Card } from './common/card'
import { Trpg } from './trpg'

export function Lab() {
  return html`
    <div>
      <${Card} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${Card} title="TRPG" class="section" semanticId="lab.trpg">
        <${Trpg} />
      <//>
    </div>
  `
}
