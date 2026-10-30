# Retained browser observation proof

An isolated native experiment executed source
`fb8d2a312b550dd6e02d5857c3ddc989c950b05e`, binary SHA-256
`2419bca114fd14727f1a9bceca65f5de2adf3c35854c0f7291968f1bd12f4f36`.
This predates the ownership/SSE follow-up at `62f9abb9a5`; it does not validate
that later code or claim current-head native coverage.

The turn had six outer calls, no errors, three navigation/content compositions
and four BrowserRead observation roots: the scoped initial navigation region,
then Alpha, Beta and Gamma. Each root is joined to its durable execution receipt
and model-visible raw result. The four saved JSON files have verified SHA-256
and byte lengths and decode to exactly the same objects returned to the model.
No keeper_artifact_read call was required in this turn.

These files were read from the isolated tool blob store after browser/server
closure. The report retains cleanup receipts and process provenance; the offline
audit validates the saved data, not historical process termination independently.
Only the four referenced observation blobs are copied. Runtime credentials,
provider configuration, unrelated trace events and other conversations are absent.

Run `python3 audit.py` from any directory. It uses sibling evidence only, checks
outer execution IDs against exact raw tool-use IDs, joins composition nodes to
receipts, checks artifact reference identity/size/hash and JSON equality, and
verifies SHA256SUMS. It does not start a browser, server or Keeper and does not
rewrite the recorded proof.

`firefox-final.png` is a separate actual Firefox screenshot. It is not an image
bound atomically to each stored observation. There is no historical TUI consumer
proof here, nor proof of the later SSE path. No claim of deterministic collection,
full website coverage, Slack behavior, or performance superiority follows from
this single fixture run. Original absolute paths in report metadata identify the
experiment; they are not dependencies of the portable audit.
