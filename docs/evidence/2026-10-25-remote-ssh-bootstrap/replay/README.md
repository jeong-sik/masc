# Exact-source shim over the existing SSH endpoint

Static ARM64 artifact run 40199085663 / artifact 12601655322 built candidate
`327fd90f7fec1a07f4ca7e5836d5cad3e8e39c15` with workflow/driver source
`9eadb31bb73bd4d66e43cb34bc6e7715a5106810`. Its downloaded checksums and
binary hash were verified before the direct SSH comparison. The static binary
SHA256 is `a53e5b79eda98a5a4a97c13e772b7b6c0fe724640078690c0445c848b6c88861`.
Its own probe names protocol 3.0.0 and release 0.64.0; the build receipt separately
binds the source commit/tree and the actual config-loading frame in CI.

The owned endpoint is the same container and pinned host key as the neighboring
native bootstrap evidence. A single frame was sent over real OpenSSH with
ControlMaster disabled to two binaries, using the same endpoint configuration,
workspace, payload and existing file:

- The installed preexisting shim returned exit 1 and a framed config refusal
  naming unknown key `env_file`.
- The candidate, copied to its own temporary path, returned a successful framed
  execution. The payload independently reported endpoint cwd, uid 1000, the
  preserved environment value, the preserved PATH tool's output and the exact
  retained file SHA256.

The before/after receipt verifies that the workspace entries/file hash,
configuration bytes and **installed old shim** hash were identical. This probe
did not replace the installed endpoint binary or edit the original config to
make the candidate pass. Raw stdout/stderr and the exact executed driver are
retained. An earlier driver attempt stopped at the expected old refusal because
it compared JSON-escaped stderr text rather than decoding the trailer; it ran no
candidate payload. The corrected attempt's receipt binds its own driver hash.

This is a direct framed OpenSSH experiment, not a Keeper tool call or a successful
bootstrap receipt. The native helper's EINTR repair must separately pass actual
CLI and bootstrap-to-Keeper replay. No production install, GitHub login,
real-model continuity or full readiness is claimed.
