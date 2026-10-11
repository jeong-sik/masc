# Approval answer receipt validation

Base: bb80ee80a30431bd8218ce736b5aa15d0326f06d.

Actual API/fetch/action RED: empty object, non-boolean settled, missing decision and unknown decision retired pending rows or reported success. 4 failed / 20 passed; /tmp/chat-tool-approval-answer-decode-red.log. Null already threw in the predecessor and remains a negative case.

The answer boundary now requires a record, boolean settled and the closed approve/deny decision. It returns the server's typed receipt with no missing-field defaults. Malformed receipts throw into the existing owned failure path, preserving pending state. Tests verify one POST only; no automatic retry was added.

Actual Keeper API and held approval suites: 79 tests passed; /tmp/chat-tool-approval-answer-decode-green.log. TypeScript noEmit exit 0; /tmp/chat-tool-approval-answer-decode-types.log. Whitespace check passed.

Limits: unknown server effect and manual re-answer reconciliation still require wait incarnation/frontier work. An independent review found an unqualified Tui_decode reference in the predecessor's .mli; TS results do not verify that OCaml interface and it must be corrected in the next child. No runtime, screenshot, CI or formal approval claim.
