# Installation readiness evidence — 2026-09-08

These observations apply to CI binary commit `6b07cc4c38c9d6eec157330427084b0997b6fdd0`
(version 0.34.0), from [Release run 34180682229](https://github.com/jeong-sik/masc/actions/runs/34180682229).
They do not establish acceptance of later onboarding, sandbox routing or #34245 changes.

- [Native macOS install](native-install.txt): downloaded artifact `10038983632`,
  actual local Apple Silicon execution with isolated HOME and no provider credentials.
  Installer writes all five executables, seeds config, starts server and verifies
  actual installed dashboard index/resources and rejection of corrupted/missing receipts.
  This host has its native libraries installed. This is not a clean macOS VM test.
  Guest shim was skipped because the macOS build artifact does not contain the Linux shim.
- [Linux x64 installation](linux-x64-install.txt): both native runner and fresh
  Ubuntu 24.04 container pass; guest shim and SHA256 sidecar are included.
  [Job 101919061507](https://github.com/jeong-sik/masc/actions/runs/34180682229/job/101919061507)
  completed successfully at 02:53:26 UTC. Runtime library prerequisites were installed
  in the fresh container as specified by the workflow.
- [Apple microVM image](apple-existing-image.txt): `container` 1.3.1 starts the
  existing `masc-sandbox:general` image with a read-only root and executes the expected
  basic programs. The image digest is recorded in [receipt.json](receipt.json).
  This does not test creation of a new image or an authenticated Keeper turn.
- [Before-fix runtime routing](sandbox-routing-before.txt): the downloaded CLI
  fails two of five process-boundary cases because a requested nerdctl build is sent
  to Docker. The new code selects nerdctl, and the same tests run against the newly
  built binary in Release CI. A source patch is not reported as a passing binary test.

`masc init` from this exact binary wrote 331 configuration files: 24 prompts,
161 tool definitions, 89 identity declarations, 53 themes, two MCP declarations,
and runtime/model overlay. It created no Keeper manifests and no skill packages.
Identity declarations are not connected accounts. Existing user skill roots are
not copied by this seed but can be discovered later by runtime configuration.

Remaining acceptance: final combined release binaries, new Linux image/tool smoke,
model credentials, first Keeper turn and sustained recovery/continuity. Linux microVM
is currently blocked by `microvm_work_volume_unsupported` in the nerdctl/Kata path;
it requires implementation work, not merely another smoke run.
