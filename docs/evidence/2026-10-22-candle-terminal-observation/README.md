# Candle terminal observations: repair and verification scope

The earlier [actual host qualification](../2026-10-22-candle-host-reconnect/README.md)
found a completed Grade's reported elapsed time increasing from 60.03 seconds
(receipt 68) to 180.05 seconds (receipt 72) as later stages progressed. The
original request/run remained the same. This was an observer rewrite, not evidence
of another provider execution.

PR #44920 addresses that G03 finding. Source is
`8057614cc68a1901f140a5190d4b0d6d38581263`; subsequent
`b8a16015e47f3ea355f434f3ce67d86d19fa57af` adds only its changelog.

- Current worker authority, original request read, Exact/schema validation,
  full Candle domain decoding and trace validation still precede any receipt reuse.
- An identical readable terminal receipt is preserved without another append.
  A matching failed append retries persistence with its first elapsed time.
- Typed unreadable/missing/changing payloads remain unavailable; they are not
  replaced by a new completion with a later timestamp.
- The actual worker result can still replace a replay-generated restart marker.
  Shared registry semantics and payout/ledger authority are unchanged.

The [independent read-only source review](independent-source-review.md) is PASS
for the four-file 8057614 delta, with no P0–P2 findings. It is a sibling review,
not a formal GitHub approval, cross-model attestation or an executed test result.
The implementation relies on the existing singleton payout worker and serialized
same-Goal owner; it does not add general concurrent first-writer registry semantics.

Three added protocol/storage regressions use the production consumer and real
registry files: repeated terminal reads before/after replay, an actual failed
log append followed by recovery, and removal/restoration of the original output
payload. The transport suite now contains ten cases. ML/MLI/test parser checks
and `git diff --check` passed locally; no local Dune build/test ran.

Selected verification [39646732161](https://github.com/jeong-sik/masc/actions/runs/39646732161)
was dispatched once on exact b8a160, with `minimal=true`, `eio_backend=posix` and
`test_candle_appraiser_transport,test_candle_appraiser_contract,test_candle_appraisal_flow`.
At its first result boundary it was in progress; no compiled test PASS is claimed
here. No CI watch or repeat dispatch was used.

The prior actual native eb484/worker b427/screenshots prove the original symptom
and original payout qualification. They do not prove this repaired native source,
its installed behavior or the full 54-item goal. Matching native/UI and operator
installation remain separate evidence boundaries.
