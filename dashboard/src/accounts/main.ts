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

const leave = (): void => { location.replace('/') }
const model = createConsole({ send: (path, init) => fetch(path, init), leave })
// The panels send through the console, which sends only while it shows
// someone and reads the session again when the server refuses one of their
// requests (`ConsoleModel.send`).
const { send } = model
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
// says: a page the browser keeps to come back to does not keep it. Nor does
// it keep a key in the field of an open form: the form of a key closes,
// and so does the field of a key in the card of an account.
window.addEventListener('pagehide', () => {
  tokens.forget()
  invites.forget()
  subscriptions.adding.reset()
  subscriptions.replacing.reset()
})
render(html`<${ConsoleFrame} model=${model} subscriptions=${subscriptions} keepers=${keepers} tokens=${tokens} invites=${invites} allowlist=${allowlist} members=${members} />`, root)
void model.load()
