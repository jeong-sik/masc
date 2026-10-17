# Keeper chat: retry, thinking, journal, and dashboard progress surfaces

This guide covers the four user-visible additions that landed with #42634.
Each section says what it is, how to turn it on, when it activates and what
its failure symptoms look like, how to see it, and how to turn it off.

## TUI: per-operation journal view (What: see one keeper operation's journal)

- **What it is:** while a keeper operation runs, its live activity (including turn-preparation steps and saved preparation reports bound to that execution) can be read
  from that operation's own journal; after it settles, the pane reads the
  settled journal. `:journal <id>` (or selecting the operation and pressing the
  journal binding; open the chat help sheet with `…?` to see active keybindings, as the footer key legend is hidden by default) opens the view.
- **Turning it on:** available by default in the TUI chat surface. No flag.
- **When it activates and failure symptoms:** the view only draws entries the
  backend has already persisted. If the journal is unreadable, the pane says
  the journal could not be read and refuses to assume it is empty instead of
  showing partial history.
- **Example:** `:journal 7` shows operation 7's journal; the anchor stays put
  when live reading flips to the settled journal.
- **Turning it off:** close the pane (`q`). There is no global switch; the
  surface is passive and only reads.

## TUI: provider retry notice (KEEPER_PROVIDER_RETRY)

- **What it is:** when a provider call is retried, the chat stream shows a
  notice (`KEEPER_PROVIDER_RETRY` frame) with the attempt number and the
  provider message id, so a slow turn is distinguishable from a stalled one.
- **Turning it on:** default on for keeper chats backed by a provider runtime
  (claude). No flag.
- **When it activates and failure symptoms:** the notice appears only after
  the runtime actually starts a second attempt. A malformed retry frame is
  projected as a protocol error and the turn keeps going; you may see
  "protocol error" once instead of a retry count.
- **Example:** `Retrying provider call (attempt 2, msg abc123)` appears inline
  in the activity pane while the turn is running.
- **Turning it off:** not user-configurable in this release. Ignoring it is
  safe; it carries no required action.

## TUI: thinking boundary (separate assistant thinking from final text)

- **What it is:** assistant output is split into a thinking channel and a
  text channel. The thinking part is shown in the activity pane as
  distinguishable (dimmed) content and is never merged into the final answer
  bubble.
- **Turning it on:** default on whenever the provider streams a thinking
  channel. No flag.
- **When it activates and failure symptoms:** if the stream marks neither
  channel, content falls back to text. A frame with an unknown channel value
  is rejected as malformed and projected as a protocol error.
- **Example:** during a long turn, dimmed "thinking…" lines appear first, then
  the answer bubble shows only the text-channel content.
- **Turning it off:** not user-configurable; the boundary follows what the
  provider streams.

## Dashboard: keeper response state and progress (keeper-response-state)

- **What it is:** the dashboard derives an explicit per-turn response state
  (for example: waiting, streaming, completed, failed) from the stored stream
  authority, and shows turn progress against it, instead of guessing from raw
  frames.
- **Turning it on:** default on in the keeper chat dashboard. No flag.
- **When it activates and failure symptoms:** state is only as fresh as the
  stored stream events. If the authority rejects a stored frame, the turn
  shows as unknown rather than a wrong state.
- **Example:** open a keeper conversation on the dashboard; the turn row shows
  its state chip and progress while the turn streams.
- **Turning it off:** not user-configurable; the chip is read-only status.

## Notes

- Retry, observer, and journal wire formats themselves are internal surfaces
  (not user-facing switches) and are documented in the code, not here.
- These surfaces are read-only views of persisted keeper state; none of them
  changes what a keeper does.
