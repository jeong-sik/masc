# Discover original accepted requests

`Lane_addon_tool_request_owner.discover` reuses the original owner namespace;
there is no Curator registry or second journal. It strictly decodes every
published record: the identity, the digest naming its request body, the
consumer's summary and the complete progress history. It checks the filename
against the exact request ID hash. It reads no request body; a load reads the
body one record names and checks it against that digest.
Another scope, a misnamed record, malformed JSON/history or an unknown namespace
entry rejects the inventory. Canonical atomic staging names are unpublished and
excluded using the existing shared filename grammar; they are never read,
deleted, promoted to accepted work or used as dispatch authority.

Discovery and known-ID load bind the already existing store parent as a held
root. The existing `Fs_compat` optional no-follow directory traversal keeps every
ancestor descriptor open throughout the callback. Missing descendants are an
empty observation only after the actual bound ancestors are synced and pass
fresh identity/UID/permission checks. Missing, unsafe or replaced parent
authority is an error. Neither read creates directories. The nested root and
borrowed descriptors are callback-scoped and must not escape.

Published records are single-link regular files owned by the current UID and
not group/other writable. The same no-follow file and parent descriptors supply
the initial bytes, file/parent fsync, offset-zero byte recheck and final path,
descriptor, ownership, link and snapshot validation. The Store's existing
durability verifier is reused rather than opening the pathname a second time.
Fresh checks also cover every ancestor after the callback. A listed file that
vanishes, or a bound file replaced during its read, is an error. This includes
same-byte atomic replacement and a symlink parent that still points to the
original inode. A replacement before that file is bound may instead supply a
fresh current record; discovery is not a frozen multi-record snapshot.

The complete scope runs in one system thread for an Eio caller, and cancellation
propagates after descriptor cleanup. On success, sorted names are checked again
before publication. This is not an atomic multi-record snapshot or a filesystem
transaction. It still requires the original process lease and serialized host
owner, followed by a fresh original-record/authority check before effects.
Known-ID reads currently enumerate the scope names as part of this common
boundary, so they incur directory work proportional to namespace size, plus
content verification and directory syncs. No new cache, size cap or retry loop
hides that cost.

Seven `test_lane_addon_request_discovery` scenarios use actual files and a fresh
Store handle for original input/progress recovery and scope isolation. They
exercise settled initial absence, missing/unsafe parent authority, damaged and
misnamed publication, unknown names, unpublished staging, listed deletion,
scope/store replacement, symlink/hardlink/FIFO, file/parent fsync failure,
same-byte replacement, parent symlink replacement, fresh permission checks and
wrong expected UID. This is fresh-handle recovery and deterministic real
filesystem mutation, not a live process/worker restart or a domain commit.

## Settle an original out of its scope

`Lane_addon_tool_request_owner.settle` moves one original out of the scope that
discovery reads, into `tool-request-owners-settled/<scope digest>/<YYYY-MM-DD>/`,
its record under `records/` and its body under `bodies/`. It first reads the
record the scope holds now, and moves nothing and returns `Settle_changed` when
that record differs from the one the caller read. The read and the move each
take the scope serializer, so the caller's lease and serialization keep the
record from changing between them, as for `advance`. The record moves first
and then its body, the reverse of publication: a settle that stops between the
two leaves a body no record names, as an interrupted retain does, never a
record without its body. A file already in the archive counts as moved, so the
store's settle call run again completes the move; a file in neither place is
an error. Only single-link regular files this process owns move, and both
directories are synced after each rename. The consumer picks the date; the
Workspace Curator uses the UTC date its chain's root ID was minted.

Nothing settles an original again once its record has left the scope, so a
body that a stopped settle left beside the scope stays there, like one a
stopped retain left. No pass, load or deploy check reads such a body; #45320
tracks collecting them.

A known-ID load reads the record and the body it names under one hold of the
same serializer, so it finds an original whole or gone, never a record whose
body a settle moved between two reads. The deploy store check runs beside a
live server and takes none of its locks: a record it read before a settle
moved it, and whose body it then finds gone, counts as absent. A known-ID load
and the deploy store check do not look in the archive; the Curator's discovery
only asks whether a child's record is there, to finish a stopped settle, and
`settled` answers only that. The caller settles only originals no pass needs
again and whose body no other record names. The `settle` group of
`test_lane_addon_request_discovery` moves real files: the record and body
arrive unchanged and leave the scope, a record that changed after it was read
stays, settling again completes a move stopped after the record, a record that
cannot move leaves the original whole, and a date that is not a day or an
original in neither place is refused.

Production Curator metadata capture and serialized scheduling, the original
HTTP/CLI semantic acceptance, uncertain domain commit recovery, Addon wake,
worker delivery and actual Off/reconnect with both UIs remain E02 integration
work. Discovery produces observations, never new execution permission.
