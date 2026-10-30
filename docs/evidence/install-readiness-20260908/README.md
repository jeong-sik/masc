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
model credentials, first Keeper turn and sustained recovery/continuity. In this
measured `6b07cc4c38` binary, Linux microVM was blocked by
`microvm_work_volume_unsupported` in the nerdctl/Kata path.
Later volume implementation and real guest measurements are recorded separately in
[Kata volume evidence](kata-volume.md).

## Later installed first-turn proof

Binary `585db68fd9253fd36a89066ddf1f92fddf361f92` from
[Release run 34185036819](https://github.com/jeong-sik/masc/actions/runs/34185036819),
macOS ARM artifact `10040419569`, passed actual installation and first-turn execution.
[Receipt](first-keeper-turn-macos.json) binds its binary SHA and freshly built image;
[tool proof](first-keeper-tool-proof.json) records the actual guest hostname/UID/path.

The installer seeded the complete browser-lanes package and no Keepers, then served
the installed dashboard. The test created a Keeper through the installed CLI,
sent a chat request, received a real Docker Execute result, checked the host-mounted
file, and matched the tool call/result/final answer in a durable checkpoint.
The model was a loopback scripted fixture. Both approval mechanisms were explicitly
allowed in the disposable workspace. No live workspace or provider credentials were used.

On this Colima host, the scratch workspace had to live under the shared home directory:
the macOS system temporary directory was not visible to Docker. The old local general
image also lacked Python, so the binary's embedded recipe was built into a separate
tag before acceptance. This is not a clean macOS VM measurement or a proof of real
model quality, Linux first-turn operation, or long-running Keeper continuity.

The same binary also passed [classic preset installation](classic-preset.json):
four nonempty role instructions, Docker profile, inherited network and autoboot
enabled. Preset files were downloaded from the binary's source commit and checked
against staged checksums; the public 0.34.0 tag was not used before publication.
With Keeper bootstrap disabled, the installed, unmodified runtime config reached
`startup.state_ready=true` without provider credentials. This measures server
readiness and preset seeding, not model turns by the four preset Keepers.
