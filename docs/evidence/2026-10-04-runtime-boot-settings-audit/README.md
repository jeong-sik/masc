# Boot-loaded Keeper settings: K1

Base: `c90981f0181aa22005d1e74ce94e47ee0877809e` (Goal delivery PR #41053).

Seven TOML-backed settings were evaluated during module initialization, before
`Keeper_runtime_config.load_and_apply` populated `Config_boot_overrides`.
The settings panel could report an applied source while metrics rotation and
heartbeat consumers retained the original defaults.

The settings now use accessors. The registry, Runtime_params default thunks,
metrics writer, debug alias, sleep/cooling consumers and telemetry default all
read them after startup. Precedence remains process environment, boot-loaded
TOML, default. Editing TOML without restarting does not refresh the boot store.
Env-only settings are outside this change.

## Validation

- 14 changed OCaml files pass parser-only checks (parser-checks.txt).
- `git diff --check` passes.
- Two authored integration cases in `test_runtime_toml_overrides.ml` load actual
  TOML after initial reads, compare seven settings rows with runtime consumers,
  rotate an 18-byte file at the configured 17-byte threshold, preserve two backups,
  verify pending restart after a file edit, and verify environment precedence in
  both heartbeat cadence and the real metrics append path.
- These native cases have not been executed. No typecheck, Dune build, CI,
  installed binary, live Keeper or production claim. This backend change does
  not alter dashboard rendering; no browser screenshot is claimed.

## Additional finding

Source review also identified an existing, separate retention edge case:
`metrics.max_rotated = 0` still creates a `.1` backup, and lowering retention does
not prune older higher-numbered backups. This PR fixes boot-time resolution; the
retention algorithm needs a separate behavior repair and native validation.
