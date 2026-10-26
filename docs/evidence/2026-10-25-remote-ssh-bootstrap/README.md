# Native SSH bootstrap: provisioning evidence and an incompatible shim

Candidate artifact run 40186926610 / artifact 12597150166 built source
`f9bf6b408afcff200131dfdd9040cba2551abab4`. Artifact checksums and the main
executable's build commit were verified before extracting the six packaged
executables and their four dylibs into an isolated runtime directory. The
bootstrap helper SHA256 is
`ab41a3c7e5a3cba2a052e55312bc8f8c8ba45d3af1f0720d3cbbb77b6a43d410`.
This is execution of candidate packaged bytes, not installation of a published
release or production deployment.

## What the actual bootstrap commands proved

The native helper ran against a new, owned Linux sshd container. Its host key
was read independently through Docker and matched against ssh-keyscan before
supplying the confirmation fingerprint. The dedicated identity was already
authorized in this fixture: this does not test password-based first key copying.
The fixture's fake `gh auth status` wrapper was removed, and no GitHub token or
login was supplied.

Three normal bootstrap invocations returned success: first preparation, repeat
with an existing 39-byte file, and a normal invocation after a refused symlink
workspace. The file includes NUL/CRLF bytes; its SHA256 and the workspace directory's owner and mode
remained identical. The symlink invocation returned nonzero with
`remote_ssh_directory_prepare_failed`; the outside target's owner, mode and
marker hash remained identical. Its exit code 124 is retained verbatim; this
driver used no timeout wrapper.

Decoded shim configuration retained its endpoint-owned `path`, `env_file` and
`scratch_root`. Only the requested root and env allowlist changed. The original
config, four resulting configs, four raw command logs and native receipt are
retained. Driver hashes identify the actually executed experiments. Paths and
container IDs inside the frozen drivers are historical fixture values.

## What did not work

The installed fixture shim was separately identified as
`ad79352d398d00eb48eebdf0bc29faacd3b4de633349e377ed81d560dc379183`.
It was not rebuilt from this source. Although it reports protocol 3 and its
`--probe` succeeded, the next actual Keeper creation failed before any tool
execution with `remote_ssh_shim_config_error: unknown key "env_file"`.
`old-shim-keeper-refusal.json` retains the failure.

Thus the CLI receipt's PASS applies to the explicit provisioning, preservation
and refusal assertions above. It does **not** prove the endpoint was usable by
a Keeper: bootstrap declared provisioned without testing a framed execution
against the written config. The next repair must verify that boundary and use
an exact-source static shim; removing the preserved environment settings would
hide the defect.

The first Keeper-harness attempt separately stopped because it required an
empty workspace. The updated harness accepts only explicitly declared initial
regular-file hashes, rejects undeclared files/symlinks/changed hashes, and checks
the same bytes after work, shutdown and resumed execution. The retained initial
workspace snapshot binds the 39-byte file to this attempt. The driver is
prepared to require its preserved environment/tool and actual file hash, but
the old shim prevented that payload from running. No real-model, sustained-use,
GitHub authentication, source-rebuilt-shim or full readiness claim is made.
