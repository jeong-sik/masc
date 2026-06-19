# Keeper v2 v12 Gap Snapshot

Source reviewed: `/Users/dancer/Downloads/v2 (12)`.

Current implementation surface: `dashboard/src` on branch `codex/keeper-fleet-surface`.

## Exists In Current Page

- Top-level keeper surfaces already exist for Overview, Work, Keepers, Board, IDE, Connectors, and Settings. Work and IDE keep compatibility route ids (`workspace`, `code`).
- The mobile shell has one nav owner for rail, drawer, and bottom tabs.
- The keeper detail path can hide the mobile bottom bar while reading chat.
- Board and Keepers are top-level routes rather than only nested Workspace/Monitor sections.

## Implemented In This Pass

- Mobile primary tabs now follow the prototype's user-facing priority: Overview, Work, Keepers, Board.
- Monitor and Command remain available through the full navigation drawer instead of occupying the mobile bottom bar.
- The `workspace` route keeps its existing route id and `section=work` default, but its visible surface label is now Work.
- The v2 primary shell now uses the prototype surface set: Overview, Work, Keepers, Board, IDE, Connectors, Settings.
- Monitor, Command, Lab, and Logs remain routeable operational/diagnostic surfaces, but they no longer occupy first-level v2 shell navigation.

## Still Missing Vs Prototype

- The desktop shell still has the dashboard header/tooling model around the prototype primary surfaces. The prototype's rail is visually simpler and places Settings at the rail bottom.
- The Work surface is route-compatible with `workspace`, but the app has not fully renamed internal copy, breadcrumbs, fallback labels, or source concepts that still correctly refer to a workspace.
- The Overview surface does not yet match the v12 prototype's exact composition for attention queue, telemetry histogram, keeper fleet cards, and context density.
- The Connectors page remains an operator-heavy status console rather than the prototype's simpler connector gate grid plus recent audit/event framing.
- The global mobile pane contract from the prototype (`data-mpane`, chat pane hiding rules, and drawer behavior) is not normalized across every surface.
- Composer parity is incomplete: binary attachments, microphone/STT behavior, and exact command affordance grouping are not implemented as prototype features.
- Stable message-turn identity linking from board posts to keeper chat turns still needs a hard data contract rather than visual-only alignment.

## Should Disappear Or Collapse

- Mobile primary Monitor and Command tabs should stay removed from the bottom bar; they belong in More while the prototype-first IA is active.
- The visible primary label Workspace should disappear in favor of Work where the user is navigating the v2 surface. Low-level code and data concepts can keep `workspace` when they refer to runtime scope or API contracts.
- Duplicate keeper fleet entry points should eventually collapse: Keepers is the v2 primary destination, while Monitor > Keeper Fleet is now a routeable legacy/diagnostic lane.
- If exact prototype parity becomes the goal, the desktop top surface tab layer should collapse into the single rail model and Settings should move to the rail footer.
- Stale gap notes under `/Users/dancer/me/memory/keeper-v2-gap-*.md` should be superseded by this repo-local snapshot when PR #21525 lands.
