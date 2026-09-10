# Rendered image evidence ingress

The completion authority already assembles `evidence_images_of_snapshot`, and
`Anti_rationalization` converts those images to multimodal goal blocks. This
chain is present in candidate `17b9c982af4ab85d120a4afbca6b59de1fc500eb`.
Its presence alone does not establish that submitted rendering bytes arrive.

Two ingress defects prevented ordinary PNG submissions from using that chain:

- Docker shared-mount artifacts used the host text reader, which refused PNG
  bytes as invalid UTF-8 before filing an image body.
- Endpoint-owned readers stored `Filename.extension` as `.png`, while the image
  MIME classifier accepted `png`.

The repair captures supported image references as complete binary snapshots,
uses one canonical lowercase extension on both paths, and refuses truncated
images. The endpoint path uses one byte of lookahead only for images. Existing
text-prefix behavior and the shared 200000-byte evidence ceiling are unchanged.
PDF rasterization is not added: submit rendered pages with `artifact:` references.
A `note:` mentioning a PNG remains a note and does not attach that file.

The inspected `vrf-d14835a4b1f16ae763aef3f80d91e4ff` snapshot contained a missing
summary and notes, with no PNG artifact reference. The later
`vrf-29d7aa6e465b7e1b5acd86f7305120f0` submission supplied summary text but still
mentioned rendered pages only as notes. These submissions do not demonstrate a
failed binary read. The model's 51200-byte statement reflects a real, separate submission gate:
`Keeper_tool_task_runtime.evidence_total_bytes_limit = 50 * 1024` rejects the
aggregate artifact size and tells the caller to use notes. The initial audit
searched numeric literals and missed that expression; its contrary claim was
incorrect. This ingress repair does not remove that gate. A separate repair and
three-image production submission proof are required.

## Verification boundaries

`test_completion_trust_harness` submits a valid PNG through actual Keeper task
dispatch. The production authority daemon consumes the persisted snapshot and
passes image blocks to a controlled reviewer adapter. That adapter uses the
production OpenAI-compatible HTTP client against a local synthetic provider;
the assertion checks the exact received PNG data URI. Replacing the producer
file after submission leaves the snapshot bytes unchanged. An oversized host
image is explicitly unreadable.

This proves submission, snapshot, authority image blocks, and provider encoding
when the fixture declares image capability. It does **not** prove production
runtime selection, a deployed verifier turn, or visual quality of any PDF.
Existing runtime capability projection tests separately cover image-capable and
text-only runtime behavior. No capability is enabled in product configuration by
this repair.

`test_keeper_sandbox_read_backend` additionally exercises the production endpoint
artifact reader through a controlled SSH executable: canonical PNG format,
filed exact bytes, oversized image refusal, and unchanged text-prefix behavior.

Local determinism lint and whitespace checks passed. Behavioral tests require
CI; no local build was run.
