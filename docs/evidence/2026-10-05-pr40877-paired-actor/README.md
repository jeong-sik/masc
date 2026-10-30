# Paired-actor regression coverage

Review 4178822347 correctly identified that changing only the preflight run actor was rejected by the single-run frozen keeper check before reaching the paired-run actor comparison. The fixture now changes the preflight frozen keeper_id too and requires the exact paired-actor refusal. Its template contains only conversation_history, so the rendered prompt bytes and hash remain unchanged.

Adding the precise error assertion first produced the recorded failure: the old fixture returned the frozen-keeper error instead. With the coherent fixture, all 46 public CLI tests passed. A temporary copy of the actual CLI with only the paired-actor guard removed caused the repaired test to fail, proving it protects that boundary. Production CLI source was never changed. Ruff and Pyright reported zero errors.

Commands from this worktree:

```sh
python3 test/test_librarian_preflight_report.py ReportCliTest.test_mismatched_or_contradictory_evidence_is_refused
python3 test/test_librarian_preflight_report.py
ruff check test/test_librarian_preflight_report.py --output-format json
pyright --outputjson test/test_librarian_preflight_report.py
```

The initial unittest module import failure is retained separately and is not regression evidence. The mutation test uses a temporary copied CLI with its actor conditional disabled, then runs the same public CLI test via its SCRIPT binding. Raw logs are byte-for-byte. This validates fixture admission coverage, not live paired experiments or full CI.
