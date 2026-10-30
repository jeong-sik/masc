# Credential expiry authority

Local source composition base: `dd52508a3212f5886d9a1e7b7cc27643336c6483`.
Branch: `fix/play-expiry-stack-20260930`.

This candidate composes original expiry commits `844c88fee5` and `602b575f2e`
on the refreshed Play repair (`62a235575d`, with its source-audit follow-up
`dd52508a32`). That local parent contains four main-overlap files in snapshot
`c178316d0a`; it is not the complete current main tree. Root reports the actual
published Play parent as `2638b8bb35a6fc14b29407000d53f0e3c68bfc95` on main's
complete `a254` tree. This read-only local audit made no GitHub request and does
not claim local history/tree identity with that publication.

Conflict resolution retains Play's create-only credential publisher, strict
transaction-bound lstat presence, revoke unreadable/mismatch refusals and 503,
and Keeper's admitted transaction through departure/release. Expiry uses Result
through those same paths. The old Play presence helper is not reintroduced.
The parent `40136.md` fragment remains unchanged; `999999.md` is a temporary
positive numeric placeholder that must be renamed and cited with the actual
child PR number before publication. CHANGELOG.md is unchanged from this parent.
Publishing must apply only this candidate's stanza insertion to the then-current
main test/dune, preserving unrelated main registrations.

`main-test-dune-patch.json` retains the exact root-provided main registration import.
The resulting test/dune, with only the child expiry include removed, is verified
byte-identical to the imported main file. Source provenance hashes that file and
patch. The preserved registrations may reference other main files absent from
this partial local clone; they are supplied by the complete published parent.
The new list refusal uses main's `Server_refusal.json`, retaining its response
contract rather than restoring the removed local error helper.
`main-routes-play-mli.txt` retains the corresponding main interface documentation.
The composed interface preserves refusal sentences in `error` and discriminants
in `code`, adding only the listing and unreadable/mismatched revoke descriptions.

## Source defects

- Credential decoding accepted any optional string as `expires_at`. Static
  lookup, owner verification, OAuth live bootstrap and Play eligibility then
  compared wire strings. A value such as `zzz` could authenticate indefinitely;
  equivalent timezone offsets and fractional timestamps produced different
  eligibility decisions.
- Inventory parsed a timestamp independently and classified it expired at
  `at <= now`. Authentication allowed the entire expiry second. At expiry+0.5
  an authenticating credential could therefore enter the prune set.
- Inventory called a malformed expiry valid rather than reporting its parse
  failure explicitly.

## Shared rule and boundaries

`Types_auth.Credential_expiry` owns strict parsing, normalization and expiry.
It uses `Time_codec.parse_rfc3339_whole_seconds`: RFC3339 timezone conversion and
Ptime truncation occur before conversion to float, so `.999999999999` does not
round into the next second. A present malformed string returns the typed
`Invalid_timestamp` error, never `No_expiry`. Expiry is `floor(now) > second`.

The credential JSON decoder rejects malformed expiry and normalizes valid input
to UTC whole seconds. The existing credential writer API is unchanged: directly
constructed malformed records may still be saved, but cannot be decoded and
used to authenticate. No invalid value is silently repaired to a non-expiring
credential. In-memory inputs are also checked by the pure domain helper.

Static lookup and owner verification share a live-credential check. OAuth's live
bootstrap check and Play's expiry projection use the same domain rule. Play's
expiry and list APIs return Result, preserving malformed input as an error.
Seats refuse invalid expiry with a warning, controller recovery retains an
ambiguous holder with a warning, and list projection returns 503 rather than
fabricating an expired row. Persisted invalid credentials fail decoding.
Inventory reports `Invalid_expiry` and excludes it from automatic prune so its
evidence remains available for operator repair. Inventory's `classify`,
`is_expired` and `expired` function signatures are unchanged.

OAuth's separate code/access/refresh grant lifetimes remain their existing float
deadlines. This change governs the credential backing the grant. It does not
implement atomic prune or change publication/locking.

## Feature regressions written, execution pending

`test_credential_expiry` drives a real temporary credential store and real OAuth
code exchange while controlling the existing Time_compat clock with Eio's mock
clock. It covers:

Every fixture explicitly enables auth and requires a token; controller recovery
therefore evaluates departures under the enforced-auth rule.

- UTC, positive and negative timezone offsets, fractional timestamps and
  positive/negative offset `.999999999999` input representing the same second.
- Canonical decoded expiry, static bearer lookup, owner verification, OAuth live
  bootstrap, Play eligibility and actual handoff targets.
- Expiry+0.5 remains live and outside the inventory prune set; expiry+1 is denied
  everywhere and enters the prune set.
- Four malformed expiries applied after warming a known bearer and minting an
  OAuth grant. Decoder, bearer verification, OAuth access and refresh, Play
  expiry projection and handoff targets refuse them; typed domain/Play/inventory errors
  preserve the input, and prune excludes malformed evidence.
- Each of the four malformed persisted expiries while holding the real DOS
  controller retains that holder through recovery and refuses another
  participant's movement. An empty stamp catches the prior lexical comparison's
  false expiry/release under enforced auth.

Existing inventory tests now require an explicit invalid classification.
The new test is registered through `test/stanzas/test_credential_expiry.inc`.

## Evidence limits

`static-checks.json` retains exact parse-only commands for the combined Play and
expiry OCaml files, `git diff --check`, and scoped source/fragment lint, all exit
0. `source-provenance.json` records source
SHA256 values. These checks establish parsing and whitespace, not native type
checking or test execution.

No local Dune/native build, native test execution, CI, network call, publication
or live runtime experiment was performed. Required finishing validation includes
`credential_expiry`, `auth`, `auth_oauth`, `auth_token_inventory`,
`auth_credential_index_cache`, `auth_credential_hash_collision`, `play_invite`,
`dos_input_routes` and `dos_tools` against the published candidate head.

The raw main patch is base64-encoded in main-test-dune-patch.json to preserve context bytes without trailing-whitespace lines. The parent route fixture uses the code discriminant in published parent 6714e7eaf75403046b69aed4d3aec55c09c01271; parent-fixture-parse.json records the additional syntax check.

Published as stacked PR #40171. The assigned changelog fragment is changelog.d/40171.md; native and required checks must cite the final public head.

## Complete current main composition (expiry)

This feature was extracted from its own local parent `dd52508a32` to source `8d6c3e9063`, then applied to complete current main `c112b2030652a5a25360f5d5322f8dc6da99c598` with immediate feature parent `c95f5df97d0614732c67144d7e5d5673c7dc6229`. Parent fixes were retained through three-way application, and the native registration was added without importing the old partial-main test/dune overlay. `current-main-composition.json` records the exact parent delta manifest, current source hashes and source checks. Retired Keeper API/implementation and every current-main test registration are preserved. Earlier provenance remains historical to its captured source.

This layer's syntax parsing, production ignore lint, changed-line ignore gate, whitespace and determinism checks pass. The additional test-inclusive scan is retained with its actual exit code and output, including any inherited fixture debt. No local typecheck, Dune, native test, runtime, network or CI was performed; root owns publication and finishing-boundary native validation.
