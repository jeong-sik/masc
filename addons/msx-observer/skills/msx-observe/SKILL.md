---
name: msx-observe
description: Read selected MSX frames and input history with their machine incarnation, source coverage, and original evidence.
---

Use this skill when a task needs an explanation of existing MSX observations.
It supplies an interpretation procedure and an optional local helper. Choose
whether that evidence is useful to the current task.

1. Inspect the existing Lane rows and select exact row IDs. Keep the installation,
   instance, observation sequence, machine incarnation, and clock domain together.
2. Read `references/observations.md` through `keeper_skill` using this skill's exact
   reference and `file`. Separate a captured frame from a game turn or a strategic
   outcome, and report incomplete source coverage with the observation.
3. For a compact projection, optionally read `scripts/summarize.py` through the same
   resource reader. Save the returned bytes in an already authorized workspace if
   execution is useful. The reader returns bytes and their SHA-256; it does not run
   the script or make the package's host path available in a Keeper sandbox.
4. The helper accepts one `rows`/`coverage` JSON document on stdin and exact
   `--row-id` arguments. It prints selected capture coordinates and evidence
   references. Use the existing execution tools and their current controls to run
   a locally saved copy. For example: `python3 summarize.py --row-id ROW_ID < observations.json`.
5. Cite the original row IDs, frame clock, observation time, source gaps, and
   evidence references in the resulting explanation. Distinguish a missing or
   delayed observation from a stopped game. Use the existing game controller only
   when the underlying task calls for a game action.

When input history matters, use the selected row's `input_ledger` evidence
reference. Its snapshot records frame, input owner, key and down/up edge through
that capture's input cursor. Null means unobserved history; a restored machine
can contain saved earlier inputs, which are not new actions in its new epoch.

Reading this skill or its resources does not load a machine, advance a frame,
send an input, change a Keeper's tools, or establish that an agent played a game.
