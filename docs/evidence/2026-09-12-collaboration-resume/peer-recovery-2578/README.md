# Peer recovery evidence on 2578

The original blocked request `kmsg-290f18125241cc7094ae744f136c574a` completed after the missing-checkpoint request was terminalized. The editor actually read build_publication.py lines 24–32 and executed wc/sha256sum: 15,999 bytes, SHA-256 178ff1f3638a9cb9e7516c0abeec1df59173f2ee7e250824754cf741f7ef5af3. The current file matches both the hash and the 232-byte Read excerpt.

The editor sent those results as `kmsg-07110a5ab15f29dd31f83f2eb29f6543`; its prompt exactly matches the designer's received run prompt. The designer posted Board comment `c-5b0bfe9d8e0806a2f7b3b08d731d6b75`, subsequently retrieved through Board/artifact Read.

Limits: the reply operation itself remains queued in Gate checkpoint reconciliation. The designer's Python codepoint calculation was deferred for approval, despite the Board wording claiming an independent environment calculation. This evidence proves actual file measurement, recipient input and Board publication; it does not prove that deferred calculation or complete reply-operation settlement. The missing original checkpoint was not recovered.

Only allowlisted raw-trace records and operational projections were exported. User-home and isolated-base paths are redacted. No token was read or exported, and no repository or live data was changed.
