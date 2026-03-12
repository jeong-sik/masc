import { html } from 'htm/preact'
import { Card } from './common/card'
import { SurfaceSemanticIntro } from './common/semantic-layer'
import { Trpg } from './trpg'
import { ToolMetrics } from './tool-metrics'

export function Lab() {
  return html`
    <div>
      <${SurfaceSemanticIntro} surfaceId="lab" />
      <${Card} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${Card} title="Tool Usage Metrics" class="section" semanticId="lab.tool_metrics">
        <${ToolMetrics} />
      <//>

      <${Card} title="TRPG" class="section" semanticId="lab.trpg">
        <${Trpg} />
      <//>
    </div>
  `
}
