# Actual API over captured workspace memory

CI run 34389200895 produced the macOS arm64 artifact 10119371436 at d8d2799059.
The staged executable reports that exact commit. Its read-only preflight accepted
all 23 operator memory snapshots and 56,694 turn records at observation time.

A separate base path received byte copies of the 23 current ordinary/source-bound
memory files from `.masc/config/keepers`, with per-file capture hashes kept locally.
The first boot lacked runtime.toml; normal `masc init` seeded the isolated config,
then the staged server booted on loopback port 18935. Its health reports the
isolated base path and expected executable hash. The authenticated context API
returned all 23 stores, zero unavailable stores, and 18 identities (including the
new empty seeded imp). This does not change or upgrade the production server.

The complete API capture is 1,073,202 bytes. Existing curator collection produces
1,710 source records and 1,440,028 serialized model-input bytes. The local model's
show API declares a 262,144-token context window. Bytes are not token counts;
this observation does not establish whether the full request fits or would be
truncated. The current curator request does not explicitly record the actual
context window used. A full-corpus model run has therefore not been claimed.
Per-Keeper grouping and actual input-window measurement are the next integration
work; the original full source inventory must remain accounted for.

Private memory text, credentials and conversation snapshots remain outside Git.
Only aggregate measurements are included here. Source attribution is captured
memory, not independent verification of the remembered claims.
