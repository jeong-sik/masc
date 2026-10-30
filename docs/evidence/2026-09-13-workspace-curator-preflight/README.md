# Candidate decoder and configuration diagnostics

Candidate a7855af2's full deployment preflight refused to take the workspace
writer lease because the existing 851f412 server (PID90054) still owns it. Its
exit 124 and original stderr are preserved under `lease-refusal/`. This was a
lease refusal, not an observation timeout or a failed store decode. The server
was not stopped and no deployment was authorized from that result.

The candidate helper's separate read-only `validate-stores` command then read
the active workspace: keeper meta 2, official-client sessions 11, ordinary memory
snapshots 2, source-bound claims 0, paused-work receipts 0, Board posts 23,
provider-input snapshots 560, and turn records 707. All reported `refused=0` and
the command exited 0. These 1,305 observed rows are not an atomic workspace
snapshot, a lease-protected preflight success, or proof of semantic continuity.

The prepared local Qwen runtime additions were appended only to a private
temporary copy of the runtime TOML. Its source hash matched the earlier
preparation receipt, and the live file was byte-identical afterward. The
candidate's `runtime-wizard-catalog --json` command parsed the copy successfully,
retained default `kimi_coding.kimi-for-coding`, and exposed
`ollama.qwen3-8-27b` with the intended local API model and endpoint. The returned
capabilities are configuration declarations, not new model measurements. No
exact-lane admission, model dispatch, live configuration apply or server
activation is claimed. The private runtime TOML is not archived here.
