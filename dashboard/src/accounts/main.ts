// The entry of the console of a signed-in person on the account server.

import { render } from 'preact'
import { html } from 'htm/preact'
import { ConsoleFrame, createConsole } from './console'

const root = document.getElementById('app')
if (root === null) throw new Error('the page of the console has no #app element')

const model = createConsole({
  send: (path, init) => fetch(path, init),
  leave: () => { location.replace('/') },
})
render(html`<${ConsoleFrame} model=${model} />`, root)
void model.load()
