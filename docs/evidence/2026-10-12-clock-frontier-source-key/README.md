# Shared execution identity for causal clocks

Timeline grouping already uses `chat_turn_key`, which distinguishes typed Operation and Autonomous_turn sources from Legacy_request display IDs. `chat_projected_timeline_ats` still keyed its first-known clock and causal floor by raw me_request_id. On a mixed-source list, identical display strings borrowed one another's clocks and moved unrelated observations onto a later execution's causal frontier.

Move the existing unchanged key type/helper above its clock consumer and use the same key in both clock tables. Preserve the existing unaddressed-row policy and same-source causal floor. No new identity parser or heuristic was introduced; existing Legacy_request grouping remains unchanged.

Interpreted the actual parent/current key helper, message_display_at and complete chat_projected_timeline_ats with minimal external source/row type definitions. Parent failed with `distinct execution sources borrowed one clock frontier`. Current passed separate Operation/Autonomous/Legacy clocks, same-source nondecreasing floor and leading unknown clock lookup restricted to its own source. Artifacts: `/tmp/masc-clock-frontier-source-20261012/{parent,current}.{ml,log}`. A later local variable rename from first_known_by_request to first_known_by_source does not change the exercised behavior.

This is clock-projection state evidence, not row-order/layout testing or full renderer execution. Existing grouping consumers and clocks now share their producer identity policy. Changed production source passed syntax-only parsing and git diff --check. No complete state fixture, full typecheck/build/CI, installation, all-provider runtime or actual UI/screenshots/formal approval/merge proof is established.
