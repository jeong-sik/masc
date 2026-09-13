# Installed discovery baseline and verifier preparation

The read-only discovery probe ran against the existing owned installation at
source 851f412, binary SHA-256
41a75acff6d190e767cebee3b53c371ed643293a41e1f1b5d93a6c5ab88c180d.
It confirmed the requested runtime identity and then failed because
`workspace-memory/publication.json` is absent. This binary predates the new
curator publication feature. The failure records that installed gap; it is not
a regression result for the new source or a successful Keeper preview test.

The probe performs GETs and reads existing files. It never writes a proposal,
starts a model, changes runtime configuration, or restarts a process. Its
successful path checks native canonical proposal bytes against the published
ID, exact HTTP readback, and each named Keeper's configuration preview. The
preview must contain exactly one complete discovery fragment rendered from the
actual Prompt Registry response, including overrides. Discovery must be absent
from stable system and persisted-user-message previews. Uncertainty markers
remain required; marker presence alone is insufficient.

Before and after observations check health, runtime source/binary/instance,
base/root paths, resolved prompt and publication bytes. These are observation
boundary comparisons, not an atomic snapshot or proof of model dispatch. A
successful result still does not establish source currency, semantic truth,
actual Keeper tool use, or later adoption. Those require separate live-turn
records and source assessment.

To use after installation, run
`scripts/verify-installed-workspace-memory-discovery.py` with explicit
`--base-url`, `--base-path`, `--token-file`, `--expected-commit`,
`--expected-binary-sha256`, one or more `--keeper`, and a fresh `--output` path.
The output directory is private; token echoes are withheld. HTTP observation
timeout is a probe failure, never authorization to stop or restart the target.

The initial baseline is retained under `pre-review/`. Independent fixture review
found two false-positive checks (null instance identity and scattered preview
markers); the probe was corrected. The current root receipt is a fresh actual
installed observation using the corrected source hash in `probe-source.json`.
Both installed observations fail at the absent publication, before preview checks.
`fixture-review.json` records 12 expected fixture outcomes: normal and overridden
prompts pass; invalid identity, scattered/duplicated fragments, message leakage,
changed prompt/base/instance/health, missing publication and token echo fail.
These local HTTP fixtures do not constitute installed feature acceptance.
Native CI, candidate installation and actual Keeper adoption remain pending.
