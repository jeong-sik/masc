# Updating builtin Skill packages

Server startup and `masc init --skills-only --base-path BASE` reconcile
`.masc/skills` with the packages the binary ships. Startup does this on every
config root, fresh or existing, so a new binary's packages reach the runtime on
restart. The installer runs the same command after committing the
binary/dashboard transaction. Before commit, `init --config-only` prepares
config for the wizard without publishing packages.

An installation receipt is a digest of the whole package, kept outside the
Skill source at `.masc/skill-packages/PACKAGE.sha256`. The digest covers every
file's bytes, every directory, and permissions. Each package gets one result:

| Installed state | Result |
|---|---|
| No package directory | installed, receipt written |
| Receipt matches the tree, tree equals this release | up to date |
| Tree equals this release, receipt absent or describing another tree | receipt written; no Skill file changes |
| Receipt matches the tree, this release differs | replaced; the previous tree is kept under `.masc/skill-packages/` |
| Receipt does not match the tree (an edit since installation) | kept |
| No receipt, tree differs from this release | kept |
| Links, special files or unreadable directories | kept |
| Receipt for a package this release no longer ships, matching its tree | tree moved under `.masc/skill-packages/`, receipt removed |
| Receipt for a package this release no longer ships, tree edited | kept |

A package without a receipt is never removed. MASC cannot tell whether it is
an untouched former builtin or the operator's own Skill. A tree that differs
only in permissions is still a different tree.

`masc init` prints one line per package and exits non-zero when any package
could not be reconciled. Startup logs the same lines and keeps starting; kept
and failed packages are warnings. A later package error during installation
keeps the committed binary and reports the failure; it does not restore an older
executable. Multiply linked resources are uninspectable: reconciliation keeps
them, and explicit replacement refuses them until the operator resolves the
shared-file relationship.

A kept package that this release no longer ships stays active. Delete its
receipt to keep it as your own Skill, or delete the Skill directory as well to
drop it.

Every replacement and retirement leaves one complete previous tree under
`.masc/skill-packages/`. Nothing removes these directories automatically.
Because an unchanged release reports every package as up to date, a backup only
appears when the shipped packages change.

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

The replacement directory is prepared and synced before one atomic exchange.
Linux uses `renameat2(RENAME_EXCHANGE)` and macOS uses
`renamex_np(RENAME_SWAP)`; unsupported filesystems fail without a two-rename
fallback. The previous directory is retained outside the Skill source under
`.masc/skill-packages/`; the command prints its path. Fresh publication and
export use the corresponding no-replace operation, so an existing empty
directory or symlink is not overwritten.

The receipt is saved after publication and parent-directory sync. A failure
after exchange is reported as **published but unrecorded**, with the previous
package's location. Inspect both trees before recovery. If the published tree
equals the release, the next reconciliation writes its receipt. A retirement
whose tree was moved but whose receipt could not be removed is reported as
**retired but unrecorded**, with the backup's location. An export whose
no-replace publication succeeded but parent sync failed reports **exported but
unsynced** with the existing destination; inspect that directory before retrying.

Serialize operator file editing with installation. The installer lock does not
lock arbitrary external editors. A running catalog must be refreshed through
its existing `/api/v1/skills/refresh` operation before a new instruction
invocation uses the update; an already-delivered instruction does not change.
