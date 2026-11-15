// The entry of the console of a signed-in person on the account server.

import { render } from 'preact'
import { html } from 'htm/preact'
import { ConsoleFrame, createConsole } from './console'
import { createKeepers, followKeepers } from './keepers'
import { createSubscriptions, follow } from './subscriptions'

const root = document.getElementById('app')
if (root === null) throw new Error('the page of the console has no #app element')

const send = (path: string, init: RequestInit): Promise<Response> => fetch(path, init)
const leave = (): void => { location.replace('/') }
const model = createConsole({ send, leave })
const subscriptions = createSubscriptions({ send, leave })
const keepers = createKeepers({ send, leave })
follow(model.view, subscriptions)
followKeepers(model.view, keepers)
render(html`<${ConsoleFrame} model=${model} subscriptions=${subscriptions} keepers=${keepers} />`, root)
void model.load()
