# Keeper v2 v12 Gap Snapshot

Source reviewed: `/Users/dancer/Downloads/v2 (12)`.

Current implementation surface: `dashboard/src` on branch `codex/keeper-v2-shell-parity`.

## Exists In Current Page

- Top-level keeper surfaces already exist for Overview, Work, Keepers, Board, IDE, Connectors, and Settings. Work and IDE keep compatibility route ids (`workspace`, `code`).
- The mobile shell has one nav owner for rail, drawer, and bottom tabs.
- The keeper detail path can hide the mobile bottom bar while reading chat.
- Board and Keepers are top-level routes rather than only nested Workspace/Monitor sections.

## Implemented In PR #21525

- Mobile primary tabs now follow the prototype's user-facing priority: Overview, Work, Keepers, Board.
- Monitor and Command remain available through the full navigation drawer instead of occupying the mobile bottom bar.
- The `workspace` route keeps its existing route id and `section=work` default, but its visible surface label is now Work.
- The v2 primary shell now uses the prototype surface set: Overview, Work, Keepers, Board, IDE, Connectors, Settings.
- Monitor, Command, Lab, and Logs remain routeable operational/diagnostic surfaces, but they no longer occupy first-level v2 shell navigation.

## Implemented In This Pass

- The desktop header no longer renders a duplicate top surface tab strip. Desktop navigation now relies on the left rail, matching the prototype's single primary nav model.
- Settings moved out of the main surface list and into the rail footer, matching the prototype's bottom-anchored Settings action.
- The mobile More drawer still exposes operational routes (Monitor, Command, Lab, Logs) while Settings remains footer-anchored.
- Opening the mobile More drawer suppresses floating status/focus chrome so the rail footer remains visible.
- The Work route's user-facing command palette label and lazy-loading fallback now say Work while preserving the `workspace` route id, and the Work footer copy matches the prototype wording.
- The Overview surface now uses the prototype's primary order and native `.ov-*` surface layer: header, six KPI tiles, attention queue, telemetry histogram, then Keeper 전체.
- Legacy Overview rollups (alerts, surface readiness, fleet ticker, task funnel, active mission, active keepers) moved into a collapsed `운영 롤업` section below the primary prototype surface.
- Mobile Overview gets extra internal scroll padding so the status tray and bottom navigation do not hide the final fleet/rollup content.

## Still Missing Vs Prototype

- The desktop shell still has a dashboard header/status/tooling model around the prototype primary surfaces. The prototype top bar is visually quieter and has fewer operational chips.
- The Work surface is route-compatible with `workspace`, but some internal breadcrumbs/source concepts still correctly refer to a workspace when they describe runtime scope or API contracts.
- The Overview surface now matches the prototype's main section order, but the exact live-data density still differs when no live keeper rows are available and the shell health/status chrome is noisy.
- The Connectors page remains an operator-heavy status console rather than the prototype's simpler connector gate grid plus recent audit/event framing.
- The global mobile pane contract from the prototype (`data-mpane`, chat pane hiding rules, and drawer behavior) is not normalized across every surface.
- Composer parity is incomplete: binary attachments, microphone/STT behavior, and exact command affordance grouping are not implemented as prototype features.
- Stable message-turn identity linking from board posts to keeper chat turns still needs a hard data contract rather than visual-only alignment.

## Should Disappear Or Collapse

- Mobile primary Monitor and Command tabs should stay removed from the bottom bar; they belong in More while the prototype-first IA is active.
- The visible primary label Workspace should disappear in favor of Work where the user is navigating the v2 surface. Low-level code and data concepts can keep `workspace` when they refer to runtime scope or API contracts.
- Duplicate keeper fleet entry points should eventually collapse: Keepers is the v2 primary destination, while Monitor > Keeper Fleet is now a routeable legacy/diagnostic lane.
- The desktop top surface tab layer should stay removed; it is now covered by the single rail model.
- The old Overview slim-home cards should stay collapsed under `운영 롤업`, not return between the KPI/attention/telemetry/fleet prototype sections.
- Stale gap notes under `/Users/dancer/me/memory/keeper-v2-gap-*.md` are superseded by this repo-local snapshot.
