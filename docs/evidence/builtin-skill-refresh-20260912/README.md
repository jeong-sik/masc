# Native builtin Skill package refresh

These commands ran against downloaded macOS CI binaries in isolated temporary
workspaces. They did not install a binary, start a server, refresh a live catalog,
or change a running Keeper's instructions.

- `permission-before.json`: source `1254542562c1b5a09504297135ee0b2d698f3fe7`
  exits 125 after an operator removes read permission from the package's
  references directory. Permission is restored after observation.
- `native-refresh-39ab.json`: source `39ab9c606f9120d3439ea4792d73f589558e9661`
  exits 0 on the same workspace and permission change, preserving the complete
  package and receipt. Nine CLI commands also exercise inspect/export, stale
  installed-digest rejection, different bundle-digest rejection, explicit
  publication, complete previous-tree retention and final recorded revision.
- Each JSON records binary SHA256, UID, commands, exit status and raw output.
  `probe.py` is the exact measurement script; its temporary input paths and
  artifact locations describe this run, not reusable product defaults.

The 39ab binary predates the mounted `.masc` root correction. These observations
do not prove that later change. Filesystem sync-failure injection is exercised
by the compiled package suite rather than this native CLI measurement. This is
installer evidence, not browser or TUI evidence.
