# One-time recall pin publication upgrade

Deploy the generation-aware reader only after the existing current pins are
converted. The previous operational inventory found 27 artifact-only pins;
that count is historical, not an expected count or permission to alter them.
This procedure preserves every artifact reference and dated history row.
The runtime deliberately has no legacy reader or automatic migration.

1. Resolve the actual base path and runtime keepers directory from the running
   server's full health response. Record the old/new binary identities. Stop
   every server, Keeper writer and blob-maintenance/GC process sharing that
   directory. Keep GC stopped throughout preparation, installation and rollback.
   Do not attempt an online conversion under only a process-local lock.
2. Make an owned, private offline backup of that keepers directory and the blob
   store; retain file ownership/modes and a checksum inventory. Do not remove
   current pins or dated history. Use the backup as the input below, never the
   active directory. Keep the original backup immutable.
3. With Python 3.14+, prepare a separate private bundle:

   ```sh
   python3 scripts/maintenance/prepare-recall-pin-publications.py \
     /path/to/offline-keepers-snapshot /path/to/new-publication-bundle
   ```

   This command writes only the new bundle. It validates normalized `_blob`
   references, rejects duplicate JSON fields and unsafe pin files, wraps each
   artifact-only pin in a fresh UUIDv7 generation, and preserves null/already
   versioned pins. Review `manifest.json`, `original/` and `replacement/`.
   Count the actual entries; do not force the historical count of 27.
4. Before installing anything, verify *all* active pin bytes against the
   manifest's `before_sha256`; abort on a missing, extra or changed pin. Verify
   replacement hashes and that every artifact is unchanged (only the envelope
   may differ). Ensure the referenced blob exists with its recorded byte count
   and SHA-256. A missing blob is a separate repair, not permission to drop a pin.
5. While every writer and GC remains stopped, install each replacement at its
   original relative path using a same-directory private temporary file,
   flush/fsync, atomic rename, and parent-directory fsync. Preserve owner and
   private file permissions. Do not install the bundle as an entire runtime
   directory, since it contains only pin files. Verify the complete installed
   set against `after_sha256` before starting the new binary.
6. Read every installed pin using the new reader, then perform authoritative
   recall for affected Keepers. Check for pin decode/retirement errors. Verify
   that a fresh publication can be observed and retired, while an older
   observation cannot retire a later publication of the same artifact. Run
   blob maintenance in observation-only mode first; resume destructive GC only
   after verifying current and dated roots. These are deployment checks, not
   checks already performed by this document.

If any install/read verification fails, keep writers and GC stopped, restore
*all* original pin bytes from the bundle via the same atomic-write protocol,
verify every `before_sha256`, and restart the old binary. Once the new runtime
has published additional pins, stop it and take a new backup before rollback;
do not overwrite newer publications with this earlier bundle.

The runtime's retain/retire path continues to own its durable cross-process
publication lock. This offline procedure neither weakens that lock nor replaces
it with inode/timestamp equality. Source parser checks and temporary-directory
migration fixtures do not establish that an operator performed this deployment.
