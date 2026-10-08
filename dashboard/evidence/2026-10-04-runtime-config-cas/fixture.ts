import { html } from 'htm/preact'
import { render } from 'preact'
import { RuntimeTomlEditor } from '../../src/components/runtime-toml-editor'
import '../../src/styles/global.css'
import '../../src/styles/tokens.css'
import '../../src/styles/keeper-v2/colors_and_type.css'
import '../../src/styles/keeper-v2/runtime.css'

render(html`<main style="max-width:1400px;margin:24px auto;padding:16px">
  <p>Synthetic HTTP fixture · actual RuntimeTomlEditor + HTTP client · no production backend</p>
  <${RuntimeTomlEditor} />
</main>`, document.getElementById('fixture')!)
