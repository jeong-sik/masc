## Frozen source refresh

The manifest and top-level native source contract describe source commit
`710b0ba62193ab1515e682fa6757e74614defd4f`. All 12 SHA-256 entries were regenerated from
`git show <source_commit>:<path>`; the committed suite registers 24 cases.
Every referenced public Auth function was checked against its `.mli`, and the
Dune include was checked as source. Six affected OCaml files parsed successfully.
No native suite, typecheck, build or CI was executed for this refresh.
The original source contract is retained under `initial_source_contract`.
Earlier prose and receipts below describe their dated compositions; their
19/20/22/23-case counts are historical, not the current inventory. Later stack
merges do not change the immutable source commit named by this receipt.

# File-backed credential publication authority

## Provenance

- Local branch: `fix/file-backed-token-authority-20260930`.
- Full local parent: `2ce17426a040220b51c5060a5549dc462f3fe425`; root verified its tree equals published parent `f80069e428c29784ad54b6387cfaeb19ff85306a` of the rotation stack.
- Production implementation commits: `f54e06b8bd78a51f9d4b2968d48300063cf373f4`, then `9d794ff3a0bb00989dd91f65000af670e3af6d78` repairs the independently identified login bootstrap bypass.
- Code and regression head: `d1535576e0d3e3141a4b878bf6e170ef46d64ade`. It includes the explicit nonblank reader condition required by the deterministic-boundary source gate.
- Root published draft [PR #40214](https://github.com/jeong-sik/masc/pull/40214) at initial head `c1bf4c05f17456e23d00070b3421e1426936e273`, parent `f80069e428c29784ad54b6387cfaeb19ff85306a`. Its whole tree `728e31539f4bf43c72546c5e13471b09494d6f5f` equals the local code head's tree. These API coordinates were supplied and verified by the root agent; this child performed no network publication or CI dispatch.
- This bundle and `changelog.d/40214.md` are added after that initial code publication. They do not provide a native verdict for an eventual updated head.

## Reachable feature defects

1. `ensure_keeper_credential` formerly read the current identity and wrote its raw bearer before credential admission. An admitted prune could remove the freshly written raw file, then ensure could recreate only its JSON and return success. An intervening Admin replacement could also be overwritten using the pre-admission Keeper UUID and role decision. Explicit recreation after prune is valid; a successful file-backed result with a missing or mismatched bearer is the defect.
2. The supplied file-backed operator publisher formerly released credential admission before writing the raw bearer. Revoke could remove the credential before that last raw write, leaving an orphan bearer despite success. Shared rotation could publish a current pair, then have its raw file overwritten by the earlier publisher.
3. CLI login separately minted the credential and wrote the bearer file. It shared the pair-publication gap and duplicated the token path without `Auth.raw_token_file`'s filename encoding.
4. A foreign UUID or owner redirect could be reused by ensure's fresh branch and overwrite another canonical credential. A direct self-UUID could make JSON publication overwrite the same path with its redirect and return an unreadable successful result.
5. The supplied-token contract accepts opaque nonblank bytes. Both public file readers trimmed those bytes, so a successfully persisted surrounding-whitespace bearer failed authentication through file clients.
6. Independent source review found a second CLI mutation route: disabled auth config called the old Admin bootstrap publisher before the new target preflight. A malformed name or foreign-owner redirect could therefore be overwritten before the final paired publisher examined it. Missing config uses the current required-auth default and does not take that enable branch.

Production callers are `Server_runtime_startup_credentials.sync_admin_token_env`, `sync_bootable_keeper_credentials`, and `Auth_login.mint`. File clients use the persisted reader in `main_eio.ml`, `masc_tui_http.ml`, and the CLI owner/model paths.

## Repair boundaries

- A private target-scoped reader uses strict name-file presence, current decode/redirect resolution, exact owner identity and UUID ownership. Missing names permit explicit creation; malformed or unreadable current material refuses mutation. The shared UUID ownership rule also refuses a payload path equal to its named credential path. Unrelated corrupt owners do not become a new global issuance gate.
- Ensure reads current ownership and raw material after admission, preserves an owned existing UUID when recreating, and reuses a current live pair with its actual role. Its existing fresh Keeper policy remains Worker with no expiry. Canonical/raw refusal precedes its separate internal-token initialization.
- Supplied file-backed publication keeps explicit replacement role and configured expiry. CLI issuance owns target preflight, bootstrap config/secret/Admin-name effects, requested lifetime, and both credential files in one admitted operation. It never re-enters a public create/save/enable wrapper while holding admission. Player login refuses before effects.
- CLI keeps the three requested lifetimes, auth-change report, URL rendering and env-var passthrough. `Auth.login_auth_change` is the shared type; the existing `Auth_login.auth_change` constructor interface aliases it. The same workspace-secret initializer remains available to the existing public enable operation.
- The private paired publisher is also used by shared rotation. It writes raw material, then credential/UUID/redirect, and invalidates the token index even on partial failure. Existing rotation publication constructors remain unchanged. Failure observation distinguishes published, unpublished and unreadable raw/credential state; file-backed APIs render that typed observation into their existing `masc_error` result.
- Public raw readers reject blank material while preserving exact nonblank bytes. CLI reads and reports the path from `Auth.raw_token_file`.

This is serialized publication, not a multi-file crash transaction. A later write failure can leave a changed raw bearer with unchanged JSON; the error reports those observed effects. Login bootstrap config/secret effects can also survive a later publication failure. No rollback or automatic repair is claimed.

## Prepared native feature regression

`test/test_auth_file_backed_transaction.ml` now registers 20 cases. Ten cases fix both orders of ensure/prune, Admin/ensure, file-backed publication/revoke, publication/shared rotation and CLI login/revoke using the existing real lock admission observer and waiter count. The remaining cases cover corrupt names, foreign UUIDs/redirects, self-UUID, directory/dangling raw material, failed admission, partial publication, opaque bytes/encoded names, missing or disabled Admin login against corrupt/foreign targets, successful disabled-config Admin bootstrap, and missing-config Admin login. The refusal case includes all four config/corruption combinations and explicitly sets `enabled = false` for its disabled branch. Missing config must report `Auth_already_required`, keep the required-auth default, create no config/secret/initial-Admin marker, and return a recoverable pair.

The stanza is included from the current `test/dune` and explicitly lists its direct libraries. `native-source-contract.json` records the 20 labels and verifies every Auth function referenced by the regression against the current public interface. It is a source check, not OCaml typechecking or test execution.

Target selectors for the root agent's finishing CI run are `test_auth_file_backed_transaction`, `test_auth_token_rotation_transaction`, `test_auth_token_prune_transaction`, `test_auth`, `test_auth_login`, and `test_credential_index_cache`.

## Static checks and limits

`initial-source-checks.json` retains the earlier source checks at production head `9d794ff3a0bb00989dd91f65000af670e3af6d78`, including the deterministic-boundary failure on `| _ -> Some contents`. The reader was changed to an explicit nonblank condition without changing its byte-preserving behavior.

`final-source-checks.json` retains source-only checks at code head `d1535576e0d3e3141a4b878bf6e170ef46d64ade`: OCaml 5.5.1 parsing for eight source/interface files, diff whitespace, deterministic boundary, finalizer, cancellation and wildcard-match gates all exited zero. The compiler stopped after parsing; it did not typecheck, link or execute the regression. `source-sha256.json` freezes source bytes, the registration and required contract.

No local Dune build, native test, CLI/server runtime exercise, CI completion, deployment or production observation was performed by this child. Parent rotation CI or source review is not a successful native result for this new publisher feature. This bundle contains no release or approval verdict.

## HTTP and file-kind follow-up

The source-only receipts and hashes above freeze the earlier code, before
review identified that surrounding-whitespace bearers survive local hashing
but change in HTTP header construction/extraction. They are historical source
receipts, not validation of the follow-up below.

File-backed publication now refuses whitespace and ASCII control bytes before
effects. Matching Keeper pairs refuse reuse with those bytes before internal
token initialization; accepted bytes remain exact. Direct opaque-token APIs
are unchanged. The accepted file-client case also invokes production HTTP
bearer extraction and MCP authentication; refusal cases compare pair/config
bytes and preserve a legacy matching pair rather than silently reminting it.

Admission reads also require regular credential/raw targets before opening
(the stat follows a regular-file symlink). A FIFO with no writer is refused,
and a bounded child regression checks named and raw FIFO paths, counterpart
and config preservation, recovery, and a regular-symlink positive case.
The kind check refuses the observed nonregular target before open; it does
not guarantee safety against an external writer replacing the path after stat.
That external follow-up registered 22 cases. These added native cases have not been run
locally; parsing and source review do not establish native or CI success.

## Native fixture failure and source repair

The root supplied the successfully downloaded `ci-run-tests.log` artifact from targeted run `36676032252`, published head prefix `9b254`, for PR #40214. Reading that raw log confirms 18 of 19 file-backed cases passed; case 18 failed at line 278 because the fixture expected `Auth_enabled` after deleting config. The source default in `lib/types/types_auth.ml` is `enabled = true` and `require_token = true`, so missing config correctly reports `Auth_already_required`. The same mistaken use of `default_auth_config` meant the supposedly disabled corruption branch was still enabled.

The fixture now persists an explicit disabled config for both the disabled refusal branch and successful bootstrap, and adds the missing-config Admin scenario described above. Production/default policy and the 19 existing scenario intents remain unchanged. The raw run also reports all 149 cases in the other nine selected suites successful; those results belong to that older published head, not the composed 23-case source.

`native-fixture-repair.json` retains the raw artifact hash, exact failure excerpt, nine suite counts, current fixture hash and source-only checks. The composed 23-case suite has not been executed locally or observed in CI. No local typecheck, link or build was performed, and no successful result is claimed for the repaired head.

## Composition freshness

External API head `68069b3af2da03639225f7bac95dcb61fb54c324` (parent9b254) was imported exactly: local staged whole tree `dd6782bc547d40d1bb45827465ec4d7a8fa503fb` equals its GitData tree. The fixture repair was applied over it; both read-kind/HTTP boundary regressions and the disabled/missing configuration distinction remain. Production, changelog and test registration bytes are preserved from680; only test/evidence files change in this follow-up. The suite registers23 cases. New source hashes freeze this composition; earlier parse/native receipts remain historical. No native23-case result, typecheck or browser result is claimed.
