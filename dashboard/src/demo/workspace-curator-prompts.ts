import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import '../styles/tokens.css'
import '../styles/surfaces-v2.css'
import { html } from 'htm/preact'
import { render } from 'preact'
import { PromptRegistryPanel } from '../components/tools/prompt-registry-panel'

const root = document.getElementById('app')
if (root) render(html`<${PromptRegistryPanel} />`, root)
