# Terminal logs need exact tool receipt coverage

Base30f7c910dfc641d54d3ab2e1d3e972a81947c9ac.

Held terminal sources unconditionally hid all durable Message_tool rows.
A terminal receipt alone does not prove all preceding tool events were retained.
Existing partial-log filtering already deduplicated activities by exact observed
execution_id; unmatched activities and omitted-step evidence remained visible.

Do not suppress tool rows at the coarse held-source filter. Apply existing exact
receipt coverage to all selected logs, including terminal held logs. Suppress
only observed execution IDs within the same source; retain unmatched/unknown
receipts and omitted evidence. Other coarse speech/skill/reasoning ownership is
unchanged. No name, position, body equality or numerical completeness heuristic.

Direct bounded probe /tmp/masc-held-tool-coverage-20261012/{probe.py,parent.ml,current.ml,parent.log,current.log}.
Actual complete log_draws_row and selected production tool coverage/filter block
interpreted. Minimal row/tool/log declarations and explicit selected-log/drawn/
held accessors; other role branches omitted. Not whole chat_rows_for, enrichment,
renderer or actual journal lifecycle. Parent exit2: terminal source without
observed tools hid durable receipts. Current exit0: missing terminal tools
retained; exact receipts deduped for full and partial logs; other source,
unidentified receipt and omitted evidence remain. Protocol/state decisions,
not wording/layout/row-order assertions.

Production syntax-only parse and diff check pass. Existing fixtures unexecuted;
independent review must inspect inherited expectations. No full typecheck/build,
CI/provider/runtime/UI/screenshots/installation/formal approval or merge proof.
Full requested multi-provider/interleaving/broadcast/async goal remains active.
