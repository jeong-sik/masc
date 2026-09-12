# Updating builtin Skill packages

`masc init --skills-only --base-path BASE` installs missing builtin packages
and updates packages whose complete directory still matches the installation
receipt. The installer runs this command after committing the binary/dashboard
transaction. Before commit, `init --config-only` prepares config for the wizard
without publishing packages. A subsequent package error keeps the committed
binary and reports the failure; it does not restore an older executable. Body edits,
resource edits, additions, deletions, empty directories and permission changes
preserve the operator's complete active package. Multiply linked resources are
uninspectable: automatic refresh preserves them, and explicit replacement
refuses them until the operator resolves the shared-file relationship. Server startup only seeds
missing packages; it does not update an existing package.

An installation receipt is a digest of the whole package, kept outside the
Skill source at `.masc/skill-packages/PACKAGE.sha256`. An existing package
without a receipt is untracked. MASC cannot infer whether it is an untouched
distribution package or an operator's own version, so it preserves it and
prints the revision and the inspection command.

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
package's location. Inspect both trees before recovery. A stale receipt leaves
the new package preserved on subsequent automatic updates. An export whose
no-replace publication succeeded but parent sync failed reports **exported but
unsynced** with the existing destination; inspect that directory before retrying.

Serialize operator file editing with installation. The installer lock does not
lock arbitrary external editors. A running catalog must be refreshed through
its existing `/api/v1/skills/refresh` operation before a new instruction
invocation uses the update; an already-delivered instruction does not change.
