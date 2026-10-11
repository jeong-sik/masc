# Approval inventory timestamp unit conversion

Base: 8ef688f1f760c1fe2cab5f4ba5c957caefb42303.

Independent decoder review held the predecessor with a numeric counterexample: finite server seconds Number.MAX_VALUE pass the primitive check but multiply to infinite milliseconds during hydration. Original SOURCE HOLD remains /tmp/masc-tool-approval-inventory-response-review-20261012/report.md.

Actual fetch/API/hydration RED: one failed / 18 passed; /tmp/chat-tool-approval-timestamp-red.log. The raw API fixture reaches hydration and produces askedAtMs Infinity before this repair.

The decoder now rejects a non-finite seconds-to-milliseconds conversion before publishing the full inventory. It uses the actual unit conversion, with no arbitrary timestamp ceiling. Null remains unknown, and normal finite conversion remains unchanged.

Actual Keeper API and approval suites: 74 passed; /tmp/chat-tool-approval-timestamp-green.log. TypeScript noEmit exit 0; /tmp/chat-tool-approval-timestamp-types.log. Whitespace check passed. Independent corrected review requested. No CI, runtime, screenshot or formal approval evidence claimed.

Malformed answer receipt handling and backend approval incarnation/frontier remain unfinished alongside the full cross-provider/TUI objective.
