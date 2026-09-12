// Source-component acceptance entry. This is outside the product entry graph.
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
  const [codebase, setCodebase] = useState('github.com_owner_a')
  return h('main', {}, [
    h('h1', {}, 'File context source acceptance'),
    h('p', {}, 'Synthetic API fixtures · production Activity panel · not an installed MASC acceptance'),
    h('label', {}, ['Repository ', h('select', {
      'aria-label': 'Fixture repository', value: codebase,
      onChange: (event: Event) => setCodebase((event.currentTarget as HTMLSelectElement).value),
    }, ['a', 'b', 'empty'].map(repo => h('option', { value: `github.com_owner_${repo}` }, repo)))]),
    h('p', {}, 'Selected source: src/shared.ml'),
    h(IdeActivityPanel, { codebase, activeFile: 'src/shared.ml', pollMs: 0 }),
  ])
}
render(h(Fixture, {}), document.querySelector('#fixture')!)
