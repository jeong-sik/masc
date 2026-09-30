# Auth metadata regular-file read boundary

This is a source candidate. No local Dune build, typecheck, native test, browser or production operation was performed. Parser and static checks do not prove executed behavior.

## Parent and scope

This reader repair is #40256. Its initial published API head is `193fba3502ace69615893c739cbc59b3e301d93b` (tree `c8b7f558f1e924242bab0516005fd381ac725ec3`), based on the actual #40214 parent below. The local source commit `ca0dba014899ef8a067eba608a30c2ce64efa980` freezes the code and eight fixture cases; later fragment/provenance updates do not change that source.

Actual publication parent: `f01a7fd45d7cc0f8e3d17b492ffd27c0b5f477c1` (#40214). Exact local full-tree parent: `33980ad07aa717c5f68e7acc51dd5de6ec21e6b5`. The local parent/tree binding was supplied by the publishing root session; the exact local tree and changed file identities are retained in `composition.json`.

This child repairs one family of file reads. A FIFO with no writer was opened by public bearer readers and configuration loading, and by related Auth/OAuth metadata readers. The configuration and OAuth cases can hold credential admission or the OAuth store lock while waiting for a writer that does not exist.

## Reachable paths

| Read | Existing production consumers | Preserved failure channel |
| --- | --- | --- |
| Raw bearer | `Auth.load_raw_token`, Login persisted reader, local clients/Keeper startup | `None` for missing, nonregular, unreadable or blank; exact nonblank bytes |
| Auth configuration | Setter/Login/rotation inside credential admission; permission gates | Secure default only for genuine absence; `Auth_config_error` for occupied unreadable or malformed configuration |
| Named/UUID credential | Verification, live freshness, admitted cold token index, explicit save/delete | Existing optional decode/read result |
| Redirect stub | Canonical lookup, alias setup, save/delete | Existing optional redirect result |
| Initial Admin | Startup Admin synchronization | Existing optional nonblank name |
| Internal Keeper hash | Internal verification and permission/role hot paths | Missing/unreadable/nonregular hash fails verification |
| Workspace secret | Uncached recovery verification and permission/role hot paths | Existing `false` on expected read failure |
| OAuth JSON | Access/family lookup under the OAuth store lock and mutex | Existing `Store_error`, lowered to a typed Auth store error |

## Implementation

The existing private typed I/O wrapper, lstat presence check and regular-file reader were moved before configuration loading. One `read_regular_auth_file` now owns the stat/file-kind/read sequence for these readers and the existing strict transaction readers. A present nonregular endpoint is refused before it is opened. Symlinks to regular files remain readable; dangling occupied paths cannot authorize mutation or become absent configuration.

Optional public readers map expected I/O/nonregular failures to their documented optional result. The uncached secret verifier maps them to `false`. Strict transaction readers retain their typed error. Eio cancellation is not among the caught I/O constructors and propagates. Login's persisted reader delegates to `Auth.load_raw_token`, sharing the existing path and read authority.

OAuth already depends on `Auth_credential_base`, so sharing the private reader introduces no dependency cycle or public API. Its exact access-hash preflight uses the existing strict presence check: a genuinely absent token still skips the store lock; a present unreadable record does not fall through to static credentials. No OAuth store, lock, cache, lifecycle or publication mechanism was added.

No credential role, lifetime, explicit replacement, pruning, mutation admission or cache policy changed. In particular, the index's handling of intact orphan UUID payloads is outside this reader repair. A named FIFO alone is not claimed to revoke an intact canonical payload.

## New feature regression source

The separate `test_auth_regular_read_boundary` suite contains eight cases:

1. Public Auth and Login readers: absence, opaque exact bytes, regular symlink, dangling link, directory and blank content.
2. Direct and symlinked FIFO bearer reads with no writer, followed by regular-file recovery.
3. Regular/symlink configuration, occupied dangling/directory refusal, and the exact secure defaults for genuine absence.
4. Configuration FIFO refusal from the actual setter, Login and rotation: both name/UUID/raw pairs and the saved config remain unchanged, bootstrap effects are absent, and all publishers work after path repair.
5. Public raw, persisted Login and configuration reads propagate Eio cancellation.
6. UUID (and optionally named) FIFO blocks no public verification, alias check or admitted cold index scan; unreadable authority is refused, raw counterpart is preserved, and the UUID owner recovers after repair/public cache invalidation.
7. Initial Admin and hot internal/secret FIFO reads refuse without blocking; an ordinary Worker still authenticates, and repaired internal/recovery credentials work.
8. OAuth-enabled access/family FIFOs produce a typed store error, preserve counterpart/bootstrap bytes, and leave store admission usable after repair.

FIFO cases fork before creating an Eio environment. Their child has a five-second fixture alarm so a blocking regression fails finitely. There is no FIFO writer, release sleep or production timeout. The parent owns and cleans the temporary workspace. This source is registered through its own stanza and `test/dune`; it does not edit the parent's file-backed regression suite.

## Verification and remaining evidence

`parse-checks.json` records eight OCaml 5.5.1 parse-only checks; `source-checks.json` records six source gates. All exit 0. `composition.json` records public test symbol declarations, source identities and unchanged publisher/index policy files. `source-sha256.json` identifies the candidate source/evidence files.

Required current-head native selectors include `test_auth_regular_read_boundary`, `test_auth_file_backed_transaction`, `test_auth`, `test_auth_login`, `test_auth_oauth`, `test_credential_index_cache`, `test_auth_token_rotation_transaction` and `test_auth_token_prune_transaction`.

The eight new cases have not executed locally. Current-head required checks and targeted native evidence remain necessary. This document makes no pass, release, installed-binary or production claim.
