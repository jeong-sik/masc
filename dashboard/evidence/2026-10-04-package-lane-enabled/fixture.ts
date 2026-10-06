import { html } from 'htm/preact'
import { render } from 'preact'
import { LaneAddonsPanel } from '../../src/components/lane-addons-panel'
import '../../src/styles/global.css'
import '../../src/styles/tokens.css'
import '../../src/styles/keeper-v2/colors_and_type.css'

render(html`<main style="max-width:1200px;margin:24px auto;padding:16px">
  <p>Synthetic HTTP fixture · actual Lane Add-ons and decoder · no worker or production backend</p>
  <${LaneAddonsPanel} />
</main>`, document.getElementById('fixture')!)
