# Auth metadata regular-file read boundary

This is a source candidate. No local Dune build, typecheck, native test, browser or production operation was performed. Parser and static checks do not prove executed behavior.

## Parent and scope

This reader repair is #40256. Current source commit `308ab9eb1d8a25c01906a7e48c055e39d4d7fd43` follows parent PR #40214 at `38b8b93ced4f3eefda8b72b03f7e04af9056fcaa`. The following evidence-only commit regenerates the source manifests without changing reader code. Fixture symbol locations from `a6938d8ac7a578ea97c1decf26851eeae45def3a` are retained explicitly as historical metadata.

The original publication and local-source provenance are retained under `initial_publication` in `composition.json`. They are historical records, not claims that later diagnostic and descriptor-reader changes preserved the original source bytes.

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

One `read_regular_auth_file` owns opening and reading for these readers and the strict transaction readers. It opens with `O_NONBLOCK` and `O_CLOEXEC`, checks that same descriptor with `fstat`, and reads only a regular descriptor. A FIFO replacement cannot wait for a writer. The post-read descriptor metadata and current path identity must agree before bytes are accepted. Symlinks to regular files remain readable; dangling occupied paths cannot authorize mutation or become absent configuration.

Optional public readers map expected I/O/nonregular failures to their documented optional result. The uncached secret verifier maps them to `false`. Strict transaction readers retain their typed error. Eio cancellation is not among the caught I/O constructors and propagates. Login's persisted reader delegates to `Auth.load_raw_token`, sharing the existing path and read authority.

OAuth already depends on `Auth_credential_base`, so sharing the private reader introduces no dependency cycle or new OAuth API. The separate test-only open adapter exposes no process-wide hook. Its exact access-hash preflight uses the existing strict presence check: a genuinely absent token still skips the store lock; a present unreadable record does not fall through to static credentials. No OAuth store, lock, cache, lifecycle or publication mechanism was added.

No credential role, lifetime, explicit replacement, pruning, mutation admission or cache policy changed. In particular, the index's handling of intact orphan UUID payloads is outside this reader repair. A named FIFO alone is not claimed to revoke an intact canonical payload.

## New feature regression source

The separate `test_auth_regular_read_boundary` suite contains nine cases:

1. Public Auth and Login readers: absence, opaque exact bytes, regular symlink, dangling link, directory and blank content.
2. Direct and symlinked FIFO bearer reads with no writer, followed by regular-file recovery.
3. Regular/symlink configuration, occupied dangling/directory refusal, and the exact secure defaults for genuine absence.
4. Configuration FIFO refusal from the actual setter, Login and rotation: both name/UUID/raw pairs and the saved config remain unchanged, bootstrap effects are absent, and all publishers work after path repair.
5. Public raw, persisted Login and configuration reads propagate Eio cancellation.
6. UUID (and optionally named) FIFO blocks no public verification, alias check or admitted cold index scan; unreadable authority is refused, raw counterpart is preserved, and the UUID owner recovers after repair/public cache invalidation.
7. Initial Admin and hot internal/secret FIFO reads refuse without blocking; an ordinary Worker still authenticates, and repaired internal/recovery credentials work.
8. OAuth-enabled access/family FIFOs produce a typed store error, preserve counterpart/bootstrap bytes, and leave store admission usable after repair.
9. Deterministic replacements immediately before and after open: a new FIFO cannot block, and a pathname replacement cannot admit bytes from the retired descriptor. The original bytes remain intact and public readers recover after repair. The test-only injected open function exercises the production reader without a process-wide hook.

FIFO cases fork before creating an Eio environment. Their child has a five-second fixture alarm so a blocking regression fails finitely. There is no FIFO writer, release sleep or production timeout. The parent owns and cleans the temporary workspace. This source is registered through its own stanza and `test/dune`; it does not edit the parent's file-backed regression suite.

## Verification and remaining evidence

`parse-checks.json` and `source-checks.json` retain the earlier checks of `a6938d8ac7a578ea97c1decf26851eeae45def3a`; they are not execution evidence for the current composition. `composition.json` binds the current source tree and per-file hashes. `source-sha256.json` hashes the current source and evidence files, excluding itself. The current files were rehashed from the committed tree; this refresh does not claim a new native test or typecheck.

No Dune build/typecheck, native test, CI dispatch, container, installed-binary or production operation was performed.
