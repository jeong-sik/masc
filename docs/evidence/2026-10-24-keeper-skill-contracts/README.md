# Keeper Skill contract review and publication

The built-in authoring instructions described async compositions as read-only
and task-specific plans as fixed-input/read-only. The current catalog admits
durable owned-job/Ask leaves; prepared inline plans also admit canonical file
operations, exact child references and upstream input templates. The authoring
instructions now follow those contracts and describe direct recipe execution
with separate preparation when inspection is needed.

Reusable instructions must preserve their evidence and applicability and check
current authority before use. Three installed, Keeper-authored review/merge
packages contained contrary procedures: lower-first Native Stack merging,
incorrect stack discovery, all-CI source approval gates and direct approval
submission. Their procedures were corrected through the existing Skill editor.
The private package source is not included here.

## Observed publication

`runtime-skill-publication.json` records the installed server identity and exact
Skill references before and after publication. Each complete original package
was copied outside the runtime and every file's byte count and SHA-256 checked
before any write. The existing editor API then validated all three candidates,
used revision CAS and its durable atomic writer to save them, and published the
catalog. Editor and disk rereads matched the proposed bytes. A final explicit
`POST /api/v1/skills/refresh` returned unchanged; a fresh catalog read contained
all three new exact references and still exposed 48 surfaces.

| Package | Body bytes before | Body bytes after | Discovery bytes before | Discovery bytes after |
| --- | ---: | ---: | ---: | ---: |
| masc-merge-gate-patrol | 4,195 | 3,470 | 681 | 397 |
| native-stack-rebind-16-layers | 3,815 | 2,820 | 581 | 413 |
| masc-pr-adversarial-read | 4,172 | 3,432 | 427 | 401 |

These counts describe the catalog payload, not model tokens or measured task
performance. The preserved historical usage totals do not measure the revised
instructions. Validation, atomic publication and readback do not establish a
new Keeper activation, a successful review/merge, or improved autonomous work.

The repository changes to the shared Keeper prompt and managed `skill-authoring`
bundle remain source changes. This operation did not replace the installed
managed bundle or change the live shared prompt override. Their delivery follows
the normal binary/bundle and prompt deployment paths.

## Verification boundary

- Existing installed-server Skill editor preview: all three runtime candidates
  accepted as instruction Skills with no diagnostics.
- Existing installed-server save: all three `saved_and_published`, followed by
  matching editor, disk and catalog rereads.
- Repository `skill-authoring` candidate: existing installed-server editor preview
  only; no save to the managed package.
- Source review of `keeper_tool_composition_catalog.ml`,
  `keeper_prepared_inline_files.ml`, and the prepare/run tool definitions.
- No local Dune build, CI dispatch, new model trial or managed-package replacement.
