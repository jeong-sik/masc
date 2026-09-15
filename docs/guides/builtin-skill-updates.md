# Updating builtin Skill packages

`masc init --skills-only --base-path BASE` brings `.masc/skills` in line with
the packages the binary ships. The installer runs it after committing the
binary/dashboard transaction. Before commit, `init --config-only` prepares
config for the wizard without publishing packages.

Server start and the probe commands that bootstrap a config root do a smaller,
additive pass: they publish packages whose directory is missing and write
receipts for trees that already equal the release. They never replace, move or
change an installed tree. Several binaries with different packages can use the
same base path (worktree builds, an older release beside a newer one), and a
start that replaced or removed packages would undo the other binary's
installation every time either one started. Startup skips this pass when
`MASC_CONFIG_DIR` is set or `MASC_CONFIG_BOOTSTRAP` is `skip` or `empty`.

An installation receipt is a digest of the whole package, kept outside the
Skill source at `.masc/skill-packages/PACKAGE.sha256`. The digest covers every
file's bytes, every directory, and permissions. Each package gets one result:

| Installed state | `masc init` | Server start |
|---|---|---|
| No package directory | installed, receipt written | same |
| Receipt matches the tree, tree equals this release | up to date | same |
| Tree equals this release, receipt absent or describing another tree | receipt written; no Skill file changes | same |
| No receipt; files and bytes equal this release, permissions differ | permissions set to the release's, receipt written | reported as pending |
| Receipt matches the tree, this release differs | replaced; the previous tree is kept as the package's backup | reported as pending |
| Receipt does not match the tree (an edit since installation) | kept | kept |
| No receipt, files or bytes differ from this release | kept | kept |
| Links, special files or unreadable directories | kept | kept |
| Receipt for a package this release no longer ships, matching its tree | tree moved to the package's backup, receipt removed | reported as pending |
| Receipt for a package this release no longer ships, tree edited | kept | kept |

A package without a receipt is never removed. MASC cannot tell whether it is
an untouched former builtin or the operator's own Skill. Setting permissions
changes no bytes and no file list; it applies only when the files, directories
and bytes are the release's. A recorded tree whose permissions were edited
after installation is an edit and is kept.

`masc init` prints one line per package and exits non-zero when any package
could not be reconciled. Startup logs the same lines and keeps starting; kept,
pending and failed packages are warnings, and a pending line names the
`masc init` command that applies it. A later package error during installation
keeps the committed binary and reports the failure; it does not restore an older
executable. Multiply linked resources are uninspectable: reconciliation keeps
them, and explicit replacement refuses them until the operator resolves the
shared-file relationship.

A kept package that this release no longer ships stays active. Delete its
receipt to keep it as your own Skill, or delete the Skill directory as well to
drop it.

Each package has one backup entry, `.masc/skill-packages/previous/PACKAGE`.
Replacing or retiring the package puts the tree it moved out of the Skill
source there, and the tree an earlier replacement kept there is deleted.
Because an unchanged release reports every package as up to date, a backup only
changes when the shipped packages change.

Trees being built, and backups about to be deleted, live in
`.masc/skill-packages/staging/`. An interrupted installation can leave entries
there; the next `masc init` deletes them and prints one line for each. An
entry under `previous/` is always complete: it arrives by one rename or
exchange of a synced tree. An installation interrupted during a replacement
can leave `previous/PACKAGE` holding the release it was installing while the
Skill source still holds the old tree; running `masc init` again replaces the
package and puts the old tree there.

Server start reads without the installer lock and takes it only when it has a
package to publish or a receipt to write. It never waits for it: when another
installation holds the lock, the start logs that nothing was reconciled and
continues. `masc init` and `skills-refresh --apply` wait for the lock and print
which lock they wait for.

For an untracked or modified package, review the actual bundled files before
choosing replacement. Use a fresh destination directory for the export:

```sh
masc skills-refresh browser-lanes --base-path BASE
masc skills-refresh browser-lanes --base-path BASE --export-to /tmp/browser-lanes-review
diff -ru BASE/.masc/skills/browser-lanes /tmp/browser-lanes-review
masc skills-refresh browser-lanes --base-path BASE --apply --expected-revision INSTALLED_SHA256 --expected-bundle-revision BUNDLED_SHA256
```

Use the installed revision from inspection and the bundled revision printed by
the actual export command. Both include all resources.
If either the installed package or the binary-embedded bundle has changed since
inspection and review, replacement is rejected.
Use replacement only after incorporating any operator changes you want to keep;
it installs the complete bundled package. Other packages are unaffected.

The replacement directory is prepared and synced, takes the package's backup
entry, and then trades places with the installed tree in one atomic exchange.
Linux uses `renameat2(RENAME_EXCHANGE)` and macOS uses
`renamex_np(RENAME_SWAP)`; unsupported filesystems fail without a two-rename
fallback. The previous directory is kept at
`.masc/skill-packages/previous/PACKAGE`; the command prints its path. Fresh
publication, retirement and export use the corresponding no-replace operation,
so an existing empty directory or symlink is not overwritten.

The receipt is saved after publication and parent-directory sync. A failure
after exchange is reported as **published but unrecorded**, with the previous
package's location. Inspect both trees before recovery. If the published tree
equals the release, the next reconciliation writes its receipt. A retirement
whose tree was moved but whose receipt could not be removed is reported as
**retired but unrecorded**, with the backup's location. An export whose
no-replace publication succeeded but parent sync failed reports **exported but
unsynced** with the existing destination; inspect that directory before retrying.

Serialize operator file editing with installation. The installer lock does not
lock arbitrary external editors: an edit made after a package was inspected and
before its tree moves goes into the backup with the tree, and an edit made after
the receipt check of a retirement is moved aside with it. A running catalog must
be refreshed through its existing `/api/v1/skills/refresh` operation before a
new instruction invocation uses the update; an already-delivered instruction
does not change.
