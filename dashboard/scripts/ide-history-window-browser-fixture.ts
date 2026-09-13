// Source acceptance entry only; excluded from the product entry graph.
import { h, render } from 'preact'
import { useState } from 'preact/hooks'
import { IdeActivityPanel } from '../src/components/ide/ide-activity-panel'
import '../src/styles/ds-theme-tokens.css'
import '../src/styles/variables.css'
import '../src/styles/tokens.css'
import '../src/styles/dashboard.css'
import '../src/styles/v2-ide.css'
import '../src/styles/ide-v2.css'

function Fixture() {
  const [compact, setCompact] = useState(false)
  const scenario = new URLSearchParams(location.search).get('scenario') ?? 'known'
  return h('main', {}, [
    h('h1', {}, 'Activity history source acceptance'),
    h('p', {}, 'Synthetic API fixtures · production Activity component · not installed MASC evidence'),
    h('label', {}, ['Scenario ', h('select', {
      'aria-label': 'Fixture scenario', value: scenario,
      onChange: (event: Event) => {
        location.search = new URLSearchParams({ scenario: (event.currentTarget as HTMLSelectElement).value }).toString()
      },
    }, ['known', 'unknown', 'empty'].map(value => h('option', { value }, value)))]),
    h('label', {}, [h('input', {
      type: 'checkbox', checked: compact,
      onChange: (event: Event) => setCompact((event.currentTarget as HTMLInputElement).checked),
    }), 'Compact layout']),
    h(IdeActivityPanel, { codebase: 'github.com_owner_history', compact, pollMs: 0 }),
  ])
}
render(h(Fixture, {}), document.querySelector('#fixture')!)
