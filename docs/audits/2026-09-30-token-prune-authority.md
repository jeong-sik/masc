# Token prune reads and retires in one credential transaction

The CLI previously computed its expired and orphaned names before entering
Auth's deletion transaction. A credential writer could renew an expired name
or replace an orphaned redirect between that read and `Auth.delete_credential`;
the prune would then remove the new usable credential under the old name.

`Auth_token_prune.run` now owns a single existing Auth credential transaction
through discovery, canonical-name reads, inventory expiry classification,
deletion and cache invalidation. No caller-supplied candidate list authorizes a
deletion. Discovery completes before the first write, so an I/O read failure
refuses the entire operation without removing an earlier candidate.

The private Auth scanner distinguishes a malformed credential from a failed
read. Malformed and mismatched credentials remain on disk. A redirect must have
the exact stored stub shape; its canonical name file and target are checked
inside the transaction. The same `lstat` presence helper used by Play treats
only ENOENT as absence. A dangling target is not an orphan and a target read
failure refuses planning. Unknown fields or invalid redirect targets supply no
deletion authority. A resolved redirect must agree with its credential's UUID;
an extra embedded UUID target must carry the same current credential. A forged
pointer refuses the whole plan before writes. The private prune deletion
operation receives only these validated paths and never re-interprets the
record through the general explicit-revocation operation.

Preview returns `Would_retire` without file or token-cache mutation. Retirement
uses a transaction-bound deletion operation over the validated paths. It unlinks
each path directly and ignores only ENOENT, so a dangling raw-token symlink is
removed rather than reported retired while remaining on disk. Every entry reports
`Retired` or `Failed`; a failed deletion can follow partial file removal. The
CLI reports that possibility, exits with an error when any deletion failed,
and counts only completed retirements. It attempts later planned entries after
an individual deletion error.

This change uses `Auth_token_inventory` as the expiry authority and does not
change its timestamp semantics. Expiry representation and boundary agreement
are a separate change.

`test_auth_token_prune_transaction` exercises the real credential store and
durable-lock admission barrier: Admin renewal before prune, orphan replacement
before prune, prune before renewal, preview, UUID artifact cleanup and cache
invalidation, a read failure before deletion, a dangling target, malformed or
mismatched files, a forged UUID targeting another live owner's credential,
actual dangling raw-token removal, partial deletion and unavailable lock admission. These are
test scenarios committed for native CI; they have not been executed locally.

Local checks are limited to OCaml 5.5.1 syntax parsing and whitespace/source
review. No local Dune build, native test, deployed CLI or runtime was exercised.
