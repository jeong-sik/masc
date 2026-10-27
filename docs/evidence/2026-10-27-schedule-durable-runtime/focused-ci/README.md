# Focused CI: original source PR46272

Actual Test run `40394461863`, source `2d8fa7543519c5c58be056f3460a2a06e76c2730`, completed successfully. This is the original repair PR head, not C2 head `a3950a1…`. The two selected suites ran 44 + 66 = **110** cases. Full-suite CI, all scheduler tests and C2 runtime correctness are not established by this result.

`raw-suite-runner.txt` is the complete original 43,473-byte log; the small original ZIP and download manifest are also retained. `selected-results.json` is the original derivative made by selecting 1-based source lines after removing ANSI SGR escapes. Its recorded source hash belongs to the raw log, not the derivative JSON. The line references were checked against the raw log during retention. Empty `ZAI_API_KEY=` / `TYPESAFEAI_API_KEY=` values are fixture stanza output, not credentials.

The original manifest's `member-0.txt` address is historical. [current-locations.json](current-locations.json) resolves retained exact copies; [submanifest.json](submanifest.json) records source and retained byte identities independently. No CI or test was run during retention.

The new durable-request regression is visible directly at raw log lines11–20: admitted work input, no duplicate world frame, no Board promotion, post-tool survival without thinking, separate A/B selection, quiet intake, checkpoint round-trip, then the case OK. The raw log retains these assertions even though the original small result selector used the truncated Alcotest case label.
