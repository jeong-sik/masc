# Review response: startup and effective setting boundaries

Baseline: `5f31164b244c745cfb10058bb1400e2d55f5faea`.

The actual baseline native loader accepted supervisor sweep 0 and 121 seconds,
zero retained backups and all 16 malformed-environment boot scenarios (eight
converted readers, each with and without runtime.toml). The repaired loader
rejects those TOML values and all 16 strict-mode scenarios, while accepting
valid settings. Environment values 0/121 are clamped to 10/120 seconds;
non-finite values resolve to the 30-second default. Zero backup count in the
environment resolves to the supported floor of one. TOML rejects it explicitly.

The supervisor module owns the finite interval bounds used by the reader,
TOML registry and Runtime_params. The metrics reader owns the backup floor.
Startup evaluates the existing registry readers before applying TOML even when
no file exists; no second list of settings was introduced.

Four actual configuration modules were compiled natively with OCaml 5.5.1 and
cached dependency objects. probe.ml executes the real load_and_apply and
readers. The manifest identifies the source hashes. Runtime_settings interface
and implementation and the complete test_runtime_toml_overrides source also
passed isolated type checks against the candidate interfaces.

The earlier eight-reader native probe was rerun and remains passing. This is
not a full server build/startup or execution of the complete TOML/rotation
integration suite. No runtime settings or files outside temporary fixtures were
changed. The original evidence remains scoped to its recorded source hashes.
