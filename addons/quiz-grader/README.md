# Quiz grader

The grader consumes the questioner's named `questions` output and the same fact
deck through the common [output connection](../../docs/guides/lane-output-composition.md).
An answer is compared with the deck record. `answerer_claimed` is the supplied
label; `actor` remains null because the worker does not receive the authenticated
requester. The host keeps that identity in the action receipt.

Each grade's `fields.question_row` contains the exact upstream row ID, lane ID,
producer coordinates and evidence reference for the retained output. The full
question can be found in that evidence without copying its choices and body into
every answer. Cross-worker references stay in fields; `related_ids` only links
rows in the grader's own output.

Use the revision and image declared by [lane.toml](lane.toml). Prepare that image
through the [package image workflow](../../.github/workflows/lane-addon-images.yml)
and load it into the Docker engine used by MASC before updating an installation's
manifest. An existing declaration can keep its `manifest_path`: reconciliation
detects the changed manifest revision and image reference, retires the old worker
and starts a new incarnation. The new worker starts with an empty score; the host
retains prior receipts and outputs. See the
[TOML installation contract](../../docs/guides/lane-addon-toml.md#변경과-제거).
