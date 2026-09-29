# Quiz grader

The grader consumes the questioner's named `questions` output and the same fact
deck through the common [output connection](../../docs/guides/lane-output-composition.md).
An answer is compared with the deck record. `answerer_claimed` is the supplied
label; `actor` remains null because the worker does not receive the authenticated
requester. The host keeps that identity in the action receipt.

Each grade's `fields.question_row` contains the exact upstream row ID, lane ID,
producer coordinates and evidence reference for the retained output. The grade
title shows the question ID. Its full prompt is the referenced row's `title`, and
`fields.choice_index` is the zero-based position in that row's `fields.choices`.
`fields.answer_fact` identifies the deck's source, incarnation, cursor and fact
ID, with the host-retained snapshot evidence; the fact's `answer` is the exact
expected value. The record cited by the fact remains the grade's row evidence.

These coordinates preserve the full prompt, selected choice and expected answer
without copying their potentially large strings into every grade. Cross-worker
references stay in fields; `related_ids` only links rows in the grader's own
output. The stdio scenarios use a 1 MiB subject and 256 KiB selected choices, both
correct and wrong, for five answerers; subsequent observation and request replay
also fit the manifest's reply envelope. These tests exercise package workers and
host-shaped source fixtures, without running a host or Docker environment.

Use the revision and image declared by [lane.toml](lane.toml). Prepare that image
through the [package image workflow](../../.github/workflows/lane-addon-images.yml)
and load it into the Docker engine used by MASC before updating an installation's
manifest. An existing declaration can keep its `manifest_path`: reconciliation
detects the changed manifest revision and image reference, retires the old worker
and starts a new incarnation. The new worker starts with an empty score; the host
retains prior receipts and outputs. See the
[TOML installation contract](../../docs/guides/lane-addon-toml.md#변경과-제거).
