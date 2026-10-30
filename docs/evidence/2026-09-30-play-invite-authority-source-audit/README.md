# Play invite credential authority repair

Current full main base: `c112b2030652a5a25360f5d5322f8dc6da99c598`.
Branch: `fix/play-current-main-20260930`.

## Source defects

1. `Play_invite.issue` checked the name before acquiring Auth admission, then
   called an overwriting token publisher. An admitted Admin renewal could be
   held before publication while an invite passed its absence check. After the
   renewal published, the invite replaced its credential with a Player token.
2. `Play_invite.revoke` treated both an unreadable name file and a readable
   credential belonging to another name as `Already_gone`. Its callback could
   therefore release a controller without a valid departure decision.
3. `Keeper_dos_controller.credential_departure` checked the name using
   `Sys.file_exists` after a failed credential read. A dangling symlink became
   "no credential" and the next movement could release its holder.

## Repair boundaries

- Auth's create-only expiry operation acquires the existing workspace credential
  transaction before checking the name file and keeps it through publication and
  token-index invalidation. The original save body is shared by its locking
  wrapper and the admitted publisher; no recursive save/create lock is acquired.
- Transaction-bound presence uses `lstat`: only ENOENT means absent. Malformed
  files, missing redirect targets, dangling symlinks and directories occupy the
  name. Other stat errors return a typed storage refusal.
- Revoke invokes its callback only for an actual deletion or absent name file.
  Unreadable credentials and owner mismatches return explicit errors; the route
  reports 503 and does not release the controller. Same-name Worker/Admin
  credentials retain their existing 409 refusal.
- The unreachable missing-expiry refusal does not perform a later unguarded
  delete, which could otherwise remove another writer's renewal.
- Controller departure carries the existing transaction to the same presence
  helper. Present files and stat/read errors preserve the holder; read or stat
  exceptions retain their cause in Auth warning logs. The old Play presence
  helper is removed. All three direct test callers now obtain Auth admission, including current main's removed Keeper case.

## Regressions added, execution pending

`test_play_credential_transaction` adds five cases:

- Hold an Admin writer at durable lock admission, queue issue after deleting the
  old Player, then release admission. The invite must return
  `Name_taken Credential`; the exact Admin token and controller must survive.
- Queue two issues under the same real admission barrier. Only the first may
  publish, and its returned bearer must continue authenticating.
- Invalid JSON, absent redirect target, dangling symlink and directory each
  refuse revoke without its callback; the real route must return 503 and keep
  the holder and name file.
- A file resolving to another owner with each of Player, Worker and Admin roles
  refuses revoke without its callback; the route preserves the credential bytes
  and controller.
- The four unreadable fixtures also run real recovery and then an operator
  movement. Recovery must retain the holder; movement must refuse with Held_by.

`test_play_invite` adds an occupied-name case for invalid JSON, dangling symlink
and directory, asserting no replacement. Existing route and transaction cases
still cover ordinary revoke, late controller recovery, non-Player refusal,
renewal/deletion ordering, cache invalidation and failed admission.

## Validation scope

`static-checks.json` retains the thirteen exact `ocamlformat --output /dev/null`
commands and `git diff --check`, all exit 0. These checks prove parsing and
whitespace only. `source-provenance.json` hashes the source and contract files.

No local Dune/native build, native test execution, CI, live runtime experiment,
network call or publication was performed. Native type checking and execution
of the added regressions remain required before a merge verdict. Requested
targeted suites: `play_invite`, `play_invite_routes`,
`play_credential_transaction`, plus the Auth credential/index suites affected
by the shared save-body extraction, `dos_input_routes` and `dos_tools`.

Independent source review found no blocking repair defect. It did not execute
the regressions.

## Refreshed main composition

The September 30 refresh retains main a254129a87bdb388ad9e967332f32b27abaf8779 agent guidance and Server_refusal responses, replaces ignored lstat metadata with an explicit unused binding, and moves the release entry to changelog.d/40136.md. refresh-parse-only.json records syntax parsing only. The prior c121 native run does not validate this refreshed source. Local composition imported only the four overlapping main files; GitData publication starts with the complete pinned main tree.

## Complete current main integration

The current local tree is cloned from complete main `c112b2030652a5a25360f5d5322f8dc6da99c598`; it replaces the earlier four-file local composition. Play source `62a235575d`, audit refresh `dd52508a32` and code-discriminant fixture `886762f483` were cherry-picked without conflicts. The main `release_retired` API and implementation and the complete test/dune bytes are preserved exactly. The new removed Keeper test retains its behavior and now obtains Auth admission for its departure read.

`current-main-source-checks.json` records OCaml 5.5.1 parsing of all thirteen scoped OCaml files, production ignore lint, the changed-line ignore gate, whitespace and committed-diff determinism checks. These pass. The additional whole-file scan including tests reports 45 inherited fixture discard sites; it is explicitly not an all-files lint pass. Historical parse artifacts remain tied to their older captured sources. No local typecheck, Dune, native, network or CI was run, and this source repair does not claim a native compiler success. Root owns current publication and fresh native checks.
