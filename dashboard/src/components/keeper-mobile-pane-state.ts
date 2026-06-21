import { signal } from '@preact/signals'

/** Mobile (≤860px) single-pane switch for the keeper workspace grid.
 * Desktop shows roster | conversation | rail side by side; below 860px only
 * one pane fits at a time, so this selects the visible one. Defaults to 'chat'
 * because entering keeper detail means a keeper is focused. Roster row select
 * and `openKeeperDetail` set 'chat'; the chat header back button sets 'roster'.
 * Read by `.kw-grid[data-mobile-pane]` and the global mobile shell.
 */
export type KeeperMobilePane = 'roster' | 'chat'
export const keeperMobilePane = signal<KeeperMobilePane>('chat')
