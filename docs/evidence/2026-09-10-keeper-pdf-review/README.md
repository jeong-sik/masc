# Actual Keeper PDF review

The isolated 17b9 runtime replayed approved Execute `appr_01a0886b-9b50-7000-8a0a-f69b80bd473a`. The exact 969-byte output blob has SHA-256 `c5e6727a5656800f04ab7f0ec38de4dc94d1406ec3fcef44904d430dab68013e` and reports exit 0. Independently observed PDF: 212846 bytes, SHA-256 `7e8b2169baea222447458b2b045e59cdf38ae57546ee20c6e1959185aaa76b29`. Docker Poppler pdfinfo reported four A4 pages. These PNGs are independent pdftoppm renders of every page, inspected visually.

Rejected against the declared three-page Goal: four pages; page 3 diagram Korean glyphs are missing; Markdown emphasis markers are printed literally; a page 2 box title is split from its page 3 body. Body Korean is now readable. The script's exit 0 and VERIFY output do not establish visual correctness. This is real Keeper-produced documentation describing synthetic memory examples, not real observations of those examples. A correction was submitted to the same Keeper. These are document renders, not Dashboard browser screenshots.

The next Keeper revision produced exactly three pages (approved output SHA-256 `42d0b96d095a35dcf332fd870ff627369b77ab93ef061cb89f728f91e9d0f38c`, 961 bytes, exit 0). Independent page 3 rendering `v3-page-3.png` shows readable diagram Korean but overlapping diagram conclusion/disclosure text. This revision remains rejected; a specific coordinate correction was returned to the Keeper. Its Task is now claimed and in progress, not completed.

Final observed revision: PDF SHA-256 `74a24bed2977316e1ca028e91163ed890c303d02c1da6141e2d891512df131c0`, 136937 bytes. Approved execution output `55ec583ae4f13bfeef0589f1e719dc08632f983970250c19d65dd7a0d63fa5f0` was independently hashed. All three pages were rendered and visually read: Korean text and diagram glyphs are visible; previous overlap and literal Markdown emphasis are gone. This establishes this document visual check, not Task/Goal completion authority, autonomous initiative or broad multimedia quality.

`task-verdict-rejected.json` is the actual system LLM Task verdict for submission `vrf-d14835a4b1f16ae763aef3f80d91e4ff`. It refers to the submitted PDF SHA prefix `163518c8`, not the independently reviewed v4 file `74a24bed`; the rejection and later visual review are separate observations.

`rejection-delivery.txt` records the actual first-verdict commit and automatic delivery/consumption of the rejection stimulus for the same Task and verification ID. This proves that notification path, not autonomous recovery completion: subsequent operator corrections also influenced the work, and the second submission still required further verification.

## Second submission: actual rejection and aggregate limit

The actual server rejected verification `vrf-29d7aa6e465b7e1b5acd86f7305120f0` at 2026-09-09 23:38:41 UTC and returned task-001 to in_progress. The verifier accepted the three-page and synthetic-disclosure criteria, but could not visually inspect the PNGs. Its other metadata objections are recorded as verifier claims, not independently established facts.

`second-rejection-and-submission-limit.txt` preserves the selected actual server lines, including the earlier keeper_task_done rejection: 497793 artifact bytes exceeded 51200. Source `keeper_tool_task_runtime.ml` defines that aggregate submission limit as `50 * 1024`; it is separate from the 200000-byte artifact reader cap. The earlier conversational inference that Keeper invented the smaller limit was incorrect. Fixing image ingestion alone does not resolve this submission blocker. Automatic rejection delivery is recorded; successful recovery and completion remain unproven.
