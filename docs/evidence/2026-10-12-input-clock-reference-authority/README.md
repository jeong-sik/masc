# Shared input-clock authority in full-list reference

The indexed context in #42562 now preserves exact source-owned batch inputs. Its older full-list reference helpers still selected raw display IDs and checked only root input existence. Comparing the new indexed context with that reference can reject the corrected behavior.

Move the existing unchanged `chat_execution_member_keys` above both consumers. `chat_request_timeline_at` and `chat_live_timeline_at` are operation-request helpers: they now select Operation member keys through the same typed mapping. Their committed-input fallback recognizes any selected member, and unrelated Autonomous/Legacy display aliases cannot supply operation clock authority. Source-aware log context continues to use its explicitly supplied source.

An interpreted audit over 400 generated histories and six operation contexts each found seven clock disagreements before the reference fix and zero afterward (2,400 contexts). It executes the actual source key, clock functions, index constructor, insertion helper and context. External row/source/role/phase types are minimal replacements, not computational doubles. The adapted deterministic generator uses input/output phases and does not execute the exact existing six-role Alcotest fixture or its layout assertions. Artifacts `/tmp/masc-owned-input-clock-frontier-20261012/{oracle-audit,corrected-oracle-audit}.{ml,log}`.

This is bounded functional clock agreement; it does not prove the reference correct for every input or certify full renderer/row order. Original #42562 review and corrected composite acceptance remain separate. Syntax-only production parse and git diff --check passed. Full fixtures/typecheck/build/CI/runtime/installation/screenshots/formal approval/merge remain unverified.
