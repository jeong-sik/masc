import { render } from 'preact'
import { html } from 'htm/preact'
import { GoalTree } from '../src/components/goals/goal-tree'
import '../src/styles/ds-theme-tokens.css'
import '../src/styles/global.css'
import '../src/styles/tokens.css'
import '../src/styles/work-v2.css'

render(html`<main><p>Goal suspension · synthetic API fixture</p><${GoalTree} /></main>`, document.getElementById('fixture')!)
