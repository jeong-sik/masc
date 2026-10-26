# F6 macOS ARM native artifact proof

This disposable CI branch uses the already registered `.github/workflows/test.yml`
workflow through a manual dispatch on `ci/schedule-native-runtime-proof-20261026`.
Its definition has only one `macos-14` ARM job and no push, schedule, workflow-call,
release, installation or deployment trigger. This workflow change is not proposed
for merging into the product or main.

The product source is fixed independently of the workflow definition:

- Product source: `94b2df25abcdfe20c658322f4156ad63f5546c34` (F6 PR #46202).
- Explicit stack base: `fix/schedule-work-continuation-20261026` at that source.
- Dispatch input: `source_sha` must equal that exact full SHA.
- Checkout uses the same literal SHA, never the workflow branch head.
- `source-selection.json` records workflow definition/event SHA, workflow ref,
  product source, run ID/attempt and the ARM platform before setup.
- `artifact-manifest.json` is written only after build and portable packaging;
  it records the embedded source and artifact sizes/SHA256 hashes. A partial
  failure artifact can contain selection/log evidence without this manifest.

The proof stack depends on the F6 branch but does not include or automatically
merge another stack. An accepted Actions run is not a completed binary build.
The five native operator binaries and portable runtime are a single-platform
core artifact, not full CI, Release/Tag qualification or production installation.
Actual model behavior is a subsequent owned-sandbox probe.

## Existing recipes reused

All build inputs and helpers come from the pinned product checkout:

- `.github/actions/setup-ocaml-toolchain/action.yml`: OCaml 5.5.1 and the existing
  OS/architecture-aware cache/bootstrap.
- `.github/actions/pin-ocaml-deps/action.yml` delegates to
  `scripts/opam-pin-external-deps.sh`. This proof uses that canonical script
  directly with `--with-compact-protocol`, matching the macOS route in
  `.github/workflows/release-build.yml`. The composite forces `--install`, whose
  script branch also attempts apt; the native release route avoids that step.
- `release-build.yml` macOS Homebrew environment, five explicit operator targets,
  distribution names and existing deployment-preflight shell wrapper.
- `opam install ./masc.opam --locked --deps-only -y`: the requested locked build
  dependencies, omitting release-only test dependencies and media tools.
- `scripts/package-macos-runtime.py`: unchanged packager, including its existing
  dependency relocation, licenses, signing, source-commit check and portable
  runtime checks. No packager or dynamic-library-copy logic is reimplemented.

The job builds only `main_eio`, `masc_tui`, `masc_browser_host`,
`deployment_preflight_helper` and `masc_exec_ssh_bootstrap`. It does not invoke
`@all`, `@check`, `@runtest`, a behavioral suite, another platform, dashboard build
or release publication. `build-commit` must match the fixed product source both
before and after packaging. The output includes the five binaries, existing shell
wrapper, the packager's runtime archive and separate proof receipts/logs.

## Definition validation and dispatch boundary

The author validates YAML with `actionlint`, checks embedded shell/Python syntax
and runs `git diff --check`; these checks do not compile the product or execute
packaging. A single explicitly authorized workflow dispatch follows publication
of this separate draft PR. The dispatch handle and actual producer state must be
reported separately. No CI watch/poll loop, automatic retry, cancellation, local
Dune build or production installation is part of this work unit.
