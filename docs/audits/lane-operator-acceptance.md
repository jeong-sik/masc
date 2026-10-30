# Lane operator acceptance

A Lane is usable when an operator can inspect actual work and act from both the
TUI and Dashboard. Installing a package or passing a build alone does not meet
this bar. Keep implementation, CI, deployed revision, and observed use separate.

## Horizontal observation view

- Show declared output lanes even when there are no observations; show retained
  observations from detached instances with their original identities.
- Keep distinct runs and instances distinguishable. Time proximity never creates
  a dependency or a task assignment. Draw only recorded relationships.
- Select an event by pointer or keyboard and inspect its exact fields, actor,
  source time, evidence references, and recorded relationships. Overlapping
  events remain individually accessible through the event list.
- Bind evidence selection to its producing instance. Mixed or unresolved owners
  must not produce a misleading enabled preservation action.
- Label frozen slices and failed refreshes. Retained data is not live confirmation.

Dashboard: Monitor → Lane Add-ons. Select a point or use Event list, then inspect
original evidence. Select this evidence and its instance prepares preservation;
it does not send evidence automatically. Clear slice returns to the latest
received snapshot.

TUI: `go Lane Add-ons` in the command palette. The summary includes the horizontal
observation timeline. Tab selects rows; j/k moves the selection and highlights
its lane. D opens technical fields and original evidence; f shows context flow.

## Remaining product acceptance

These are required before declaring the complete Lane product finished:

- Dashboard guided package preview, schema input, installation, and subscription
  management must match the TUI capabilities and consume the same contracts.
- Builtin service lanes, external Add-ons, Keeper activity, and task/goal links
  must be navigable together using recorded identities. Unknown links remain
  unknown; package names and text similarity are not assignment evidence.
- Source change → observation → subscribed Keeper read/ack → next task decision
  must be demonstrated with actual retained receipts on the deployed revision.
- World Curator proposals must be checked against original execution outcomes.
- Test both clients against the same workspace, including failures, replacement,
  empty observations, refresh, and original-evidence navigation. Record browser
  screenshots and terminal interaction evidence from the resulting artifacts.

Design reference: [Grafana state timeline](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/state-timeline/)
for parallel entity rows and explicit event inspection. MASC observation points
are not durations or inferred execution spans.
