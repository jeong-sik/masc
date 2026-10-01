# Item account observations belong to one workspace

## Finding

Composing Item account PR #40029 with remote roster PR #40053 exposes a real
authority violation. Item accounts are keyed by Keeper name. Pending detail
reads carry a monotonically increasing request generation, but the workspace
transition previously invalidated only chat/history, not detail requests or
Item accounts. A and B can both name `alpha`: A's wallet, prices and ownership
can then be presented as B's, and a delayed A request can still be accepted.

The finding follows the production request, response-admission and render
paths, and was independently reviewed. No failing native reproduction has
been measured yet. Earlier 885 and 3d2 evidence predates this Item composition
and does not prove this fix.

## Repair

- The existing workspace transition withdraws Keeper detail as well as chat
  to the current roster. A fresh detail entry invokes the existing selected
  tab reader; it cannot remain on A's facts while B's roster settles.
- Clear pending detail tokens and the Item account/error at that transition.
  Keep the monotonically increasing generation counter. Old replies have no
  current token, including A→B→A; reopening creates a new token. A second
  workspace-generation field would duplicate this authority invalidation.
- An accepted failed Item read withdraws the account rather than allowing a
  previous Ready value to outrank its error in rendering.

No purchase/equip semantics, arithmetic, HTTP wire schema, permissions,
refresh cadence or ledger state change. Generic detail-token invalidation
also rejects stale config/sandbox/identity readers using the same mechanism.

## Verification scope

`test_tui_item_workspace_authority_pty` drives the actual TUI through isolated
HTTP fixtures: A ready account, held A refresh, B authority with the same
Keeper, late response, B ready/failed/Off/recovered reads, and current A after
return. It asserts withdrawal of the detail, absence of old money/ownership,
and no Keeper POST. Frames, complete PTY bytes, request events and binary
hashes are uploaded as `tui-item-workspace-authority`.

The finishing selection also includes existing local/remote Portrait PTYs,
held chat history, actual authenticated Item account HTTP/purchase fixtures,
and tab-strip/keyboard guards. Actual model quality, deployment and live
continuity remain separate. Native implementation head `f4041a99a7d86886336e4838588dc2f4e47f3b74`
passed all9selected suites in run36654016413. [Complete raw evidence](../evidence/2026-09-30-item-workspace-authority-f404/README.md)
retains its source identity, frames and limits. Subsequent heads contain
functional changes, including the production roster's Candle account revision,
same-revision Item retry, preview handling and parent integration. The retained
run does not validate those changes. At `6190ce0cc59facefd1bad136f928c56e7319231e`,
those paths were reviewed in source but the new native assertions had not run;
the Test workflow was manually disabled. This documentation correction adds no
native execution evidence.

The later functional integration `5ceef366cbfdd9f0e6e9244e7c6394be73be2b74`
also carries endpoint authority checks and Item roster isolation. No native run
for that head is recorded here. The archived `f404` binary, its nine-suite
results, and their hashes remain historical; they do not validate any later
functional head. The earlier disabled-workflow observation is historical too,
not a statement about the workflow's current availability.

Under the current [execution protocol](../constitution.xml), ordinary stacked
PRs require independent review of their current heads and resolution of P0–P2
findings. Absence of a new CI run does not itself block their review or merge.
This audit supplies neither that independent verdict nor new runtime proof.
Release/Tag publication still requires completed full verification of its
selected release head; the archived run cannot substitute for it.
