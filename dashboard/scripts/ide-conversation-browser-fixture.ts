// Source-only browser fixture. No runtime writes or installed acceptance.
import { h, render } from 'preact'
import { IdeConversationRail } from '../src/components/ide/ide-conversation-rail'
import { routeServerPushEvent } from '../src/sse-store'
import { route } from '../src/router'
import '../src/styles/ds-theme-tokens.css'
import '../src/styles/variables.css'
import '../src/styles/tokens.css'
import '../src/styles/dashboard.css'
import '../src/styles/v2-ide.css'
import '../src/styles/ide-v2.css'
route.value = { tab: 'code', params: { section: 'ide-shell' }, postId: null }
render(h('main', {}, [
  h('h1', {}, 'Reaction Thread source refresh'),
  h('p', {}, 'Production source component · synthetic API responses · not installed acceptance'),
  h('button', { id: 'board-push', onClick: () => routeServerPushEvent({ type: 'comment_added', post_id: 'post-1', comment_id: 'comment-1' }) }, 'Simulate Board invalidation'),
  h('button', { id: 'decision-push', onClick: () => routeServerPushEvent({ type: 'keeper_turn_complete', keeper_name: 'editor' }) }, 'Simulate Keeper turn completion'),
  h(IdeConversationRail, {}),
]), document.querySelector('#fixture')!)
