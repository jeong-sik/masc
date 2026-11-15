// The entry of the console of a signed-in person on the account server.

import { render } from 'preact'
import { html } from 'htm/preact'
import { createAllowlist, followAllowlist } from './allowlist'
import { ConsoleFrame, createConsole } from './console'
import { createInvites, followInvites } from './invites'
import { createKeepers, followKeepers } from './keepers'
import { createMembers, followMembers } from './members'
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
const invites = createInvites({ send, leave })
const allowlist = createAllowlist({ send, leave })
const members = createMembers({ send, leave })
follow(model.view, subscriptions)
followKeepers(model.view, keepers)
followTokens(model.view, tokens)
followInvites(model.view, invites)
followAllowlist(model.view, allowlist)
followMembers(model.view, members)
// A token or a link made is shown until the page goes away, as its box
// says: a page the browser keeps to come back to does not keep it.
window.addEventListener('pagehide', () => {
  tokens.forget()
  invites.forget()
})
render(html`<${ConsoleFrame} model=${model} subscriptions=${subscriptions} keepers=${keepers} tokens=${tokens} invites=${invites} allowlist=${allowlist} members=${members} />`, root)
void model.load()
