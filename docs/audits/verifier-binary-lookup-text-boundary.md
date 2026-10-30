# Verifier binary lookup text boundary

The live `task-001` submission `vrf-1d46f3c204a6906a9cdd574e6752575c`
was committed as Done at `2026-09-10T13:47:07Z`, with an approved
`system_llm_agent` verdict from `kimi_coding.kimi-for-coding`. This status
is separate from the observation serialization defect below.

The completed verification's JSONL row contained invalid UTF-8 in two
`tool_read_file` output excerpts: a 400-byte PDF excerpt and a 1024-byte
PNG excerpt. Both had been recorded as completed lookups. The dashboard
verification-runs response consequently failed strict UTF-8 decoding.
The live files, task, verifier, and server were inspected without mutation.

`Verification_authority_tools.dispatch` exposes text results. It now validates
that boundary with the existing `String_util.is_valid_utf8`. A non-UTF-8
backend result becomes a lookup error carrying the response byte count and
SHA-256, without presenting arbitrary bytes as successful text. The digest
identifies the backend response, not the source file. Existing valid UTF-8
results and errors keep their original disposition and content.

The regression scenario writes PDF-header and PNG fixtures, invokes the real
advertised Read descriptor and owned-file handler, and persists the resulting
failed observations through the verification registry. It checks replay and
the API JSON projection remain UTF-8. It does not execute a model or an HTTP
server. CI execution is reported in the PR; test source alone is not a pass.

This change does not repair previously corrupted journal rows and does not
add PDF analysis. The shared Keeper Read handler still returns text slices;
`keeper_artifact_read` has separate UTF-8/base64 paging, which is byte retrieval,
not image understanding. Verifier lookup currently has a text-only result
contract. Submitted image snapshots reach the reviewer through its existing
image-block path; the verifier's three-tool lookup surface has no PDF renderer.
