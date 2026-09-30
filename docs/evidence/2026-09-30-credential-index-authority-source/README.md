# Credential index current named authority

## Current bound UUID and stored alias follow-up

Source commit `487c4b02d920adcf5d97c1b6e659ec8a1f0a1d08` extends the original repair on immutable local parent `7dafe7e671cfbce6aeb0cf047dcd67516daad48c`, tree `9ae5a41149b3a03fad5a3ed329b5141978facb21`. Root supplied actual publication parent `f81dc06dfaeb2c8cdd8d19ddb06003c0ea1f2f03`, whose complete tree matches this local synthetic parent. The two external f81 files were imported byte exactly before reapplying the same source repair; corrected Auth base comments and the historical README hash-scope correction are preserved. Original source receipts below remain historical; the follow-up source identities and checks are recorded separately in [bound-alias-followup/composition.json](bound-alias-followup/composition.json), [source-checks.json](bound-alias-followup/source-checks.json), and [source-sha256.json](bound-alias-followup/source-sha256.json).

The original index repair did not cover `verify_token`'s direct `Some credential` branch. An intact old Admin UUID could still authenticate when selected by its UUID filename or a stored redirect alias, and `Auth.check_permission` used that verification result. The owner's named binding could meanwhile be missing, malformed, or replaced by a Worker. Reading the UUID as data did not authorize this stale credential.

Static hash-match verification now runs the existing expiry helper first, then the existing complete current named credential comparison. A stale binding returns typed `Auth_error.InvalidToken`. Existing expiry errors and OAuth mismatch/missing fallback paths are preserved. Public function signatures, direct credential data lookup, regular readers, cold/cache authority repair and test registrations are unchanged. No policy, retry loop, cache setting or counter was introduced.

The same seven feature cases now seed a real stored redirect alias before each external transition. The six transition cases prove UUID and stored alias Admin verification and actual `Auth.check_permission CanAdmin` access before the transition, then require typed `InvalidToken` from both APIs after it. They preserve exact old UUID and alias bytes and continue reading both as data. The healthy case adds positive current UUID/stored alias verification and permission controls alongside existing generated/Keeper aliases, Play and MCP entrypoints.

Four OCaml 5.5.1 files parsed and targeted lint/committed diff gates passed. The revised seven cases have **not been executed** by this child; prior native cases omitted the new bound-alias assertions. No local typecheck, build, native test, network or CI run was performed. Root owns independent review and exact published-head verification.

## Source composition

Implementation started from immutable Reader source parent `af47f73fa32b5815cfc98346cc39c2d1213aba7d`, tree `af0d0b59812c5c529d0c8174abac51d5f6b5f544`, obtained from the local Reader clone. The final local Reader parent is `f510f860016d50e792a7b71865a7e9d66ded3b14`, tree `1cd93a0ce54979756a329bef9945fc6ef61c84d2`. Its assignment update changes Reader documentation and its numbered fragment; production and tests are unchanged. No Git network operation was used. This child's assigned fragment is `changelog.d/40259.md`.

Implementation and prepared regression commit: `73b0f50f1d5fa457adcfad65b4ea3d6dd7635248`. The subsequent evidence update changes this README and adds only `composition.json`, `source-checks.json` and `source-sha256.json`; source/interface, fixture and registration bytes are frozen at that commit.

Root supplied the Reader [PR #40256](https://github.com/jeong-sik/masc/pull/40256) publication parent `46fb0eec8680e1dd0ded7ff341144972178320d2`, whose tree matches the final local Reader tree above. Root published this child as [PR #40259](https://github.com/jeong-sik/masc/pull/40259), initial head `25a83f6eaf87818b094f2f1e2ea373c1cdd9caa2`, tree `74bafec231551e111deb7db099717fb0bc55bbca`. These publication coordinates were supplied by root; this child performed no API/network publication. The assigned-fragment follow-up changes only that fragment and three evidence files, not production, fixtures or native registrations. No index native/CI result is asserted for either the initial publication or this follow-up.

The own production delta changes the cold authentication index in `Auth_credential_base` and the rebuild result in `Auth_credential_token`, with documentation in their public interfaces. `test/dune` gains one additive include for the new seven-case fixture. Public `list_credentials`, direct UUID data lookup, token lifetime, role policy, credential publication, regular-file readers and OAuth behavior are preserved.

## Reachable authorization defect

An intact UUID payload can survive an external replacement, corruption or removal of its owner's named file. Previously, `list_credentials` could discover that old payload directly and deduplicate the owner before seeing its new named credential. `fresh_matches_for_token_hash` detected stale initial candidates but accepted rebuilt candidates without checking their current named binding again.

This allowed an old Admin bearer to resolve from its intact UUID after its named authority became unknown. `verify_token` could recover it through the existing owner-alias fallback, so normal MCP permission rechecking did not protect that case. With a readable current Worker replacement, exact named verification could refuse the old token, but token-bound HTTP permissions used the indexed Admin role directly. Play invite issue/list/revoke use that production token-bound `CanAdmin` admission.

The current named credential is already the authority used by full-field freshness checks, exact-name verification, renewal and shared rotation. The existing direct UUID lookup test establishes a data-reading capability; it does not establish multiple independent bearer authorities for one name.

## Repair

Cold index construction stays under the existing Auth transaction. Directory records discover distinct owner names; the builder sorts those names and reads each current named binding, accepting only an exact owner match. That current record supplies the token hash and role, independent of directory enumeration order.

The stale-cache path rebuilds once, then applies the existing complete credential comparison to the rebuilt token bucket. A remaining change is `Auth_error.InvalidToken`; there is no retry loop, new cache counter, lifetime, timeout or role gate. Public UUID payload reads and inventory/list data remain available.

## Prepared feature regression

`test/test_auth_credential_index_authority.ml` registers seven cases: cold and warm lookup for missing named authority, malformed regular named authority, and a current Worker replacement, plus healthy UUID-backed owner and supported alias continuity. All six transition fixtures retain the old Admin UUID bytes exactly. They assert old-bearer denial through static/general lookup, exact/generated-alias verification, production Play token-bound `CanAdmin` admission and the MCP auth entrypoint. The Worker cases assert successful current-bearer resolution, its complete current role, generated alias continuity, normal MCP admission and Play Admin refusal. The positive case includes canonical, short redirect, generated and Keeper transport aliases and current Admin HTTP permission.

These are isolated temporary workspace fixtures. HTTP request objects call production authorization functions without launching a server or performing an HTTP mutation. No old UUID file is deleted or corrupted to hide the authority defect.

## Checks and limits

The source receipts record OCaml 5.5.1 parsing only, targeted ignore-comment lint, diff whitespace, committed diff gates and public API/registration checks. Parsing is not typechecking, linking or native execution. Source hashes freeze the own code, fixture, registration, fragment and required contract; parent preservation receipts cover the existing feature suites and interfaces.

No local Dune build, typecheck, native test, server/CLI runtime, network, CI result, installation or production observation was performed for this child. Its seven cases are prepared and have not been run. Parent source checks and older native results do not prove this index change. Root owns independent review, publication and exact published-head CI evidence.

## Current index documentation correction

After the first published source was reviewed, two retained cache/bucket comments were corrected to describe sorted current named owners and complete-record collision checks. The original `composition.json`, `source-checks.json` and `source-sha256.json` remain historical receipts for the preceding candidate; the original Auth base hash no longer identifies the file with corrected comments. The remaining eight recorded source hashes are unchanged. The correction changes no OCaml expression, interface, fixture or registration, and does not expand the scope of prior native evidence to a new head.
