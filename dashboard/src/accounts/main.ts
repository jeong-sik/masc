// The entry of the console of a signed-in person on the account server.

import { render } from 'preact'
import { html } from 'htm/preact'
import { ConsoleFrame, createConsole } from './console'
import { createKeepers, followKeepers } from './keepers'
import { createSubscriptions, follow } from './subscriptions'
import { createTokens, followTokens } from './tokens'

const root = document.getElementById('app')
if (root === null) throw new Error('the page of the console has no #app element')

const send = (path: string, init: RequestInit): Promise<Response> => fetch(path, init)
const leave = (): void => { location.replace('/') }
const model = createConsole({ send, leave })
const subscriptions = createSubscriptions({ send, leave })
const keepers = createKeepers({ send, leave })
const tokens = createTokens({ send, leave, now: () => Date.now() })
follow(model.view, subscriptions)
followKeepers(model.view, keepers)
followTokens(model.view, tokens)
// A token made is shown until the page goes away, as its box says: a page
// the browser keeps to come back to does not keep it.
window.addEventListener('pagehide', () => { tokens.forget() })
render(html`<${ConsoleFrame} model=${model} subscriptions=${subscriptions} keepers=${keepers} tokens=${tokens} />`, root)
void model.load()
