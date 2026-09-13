# Observed-claims instruction override cohort

The native fd441 binaries and original bundle export remain unchanged. Only
browser-lanes/SKILL.md was replaced with source 9109071810955b29163077ba3837e586d0118739.
instruction-source-proof.json records old/new hashes and the full package inventory;
the audit checks the actual second keeper_skill reply against that installed body.
This is an instruction override experiment, not a new binary release.

Six outer calls, zero errors, three compositions, four retained scenes and 53
TUI frames were observed in 40.461 seconds. These single-run measurements do not
prove causal speed or universal quality improvement. The prior full-native cohort
is preserved separately and did not load this instruction.

Manual answer review found the earlier unsupported cross-channel dependency/order
claim absent, with owner/mention/coverage handling correct. Beta's Korean wording
“현재 결정: ... 완료” remains ambiguous compared with “완료하기로 결정”: completion
is planned, not established as done. answer.txt preserves the exact terminal answer.
No algorithmic semantic-accuracy or universal-quality proof is claimed.

Run python3 audit.py from any directory in the complete repository archive.
The portable audit reuses ../compare_runs.py and the browser-continuity audit helper,
checks exact result slices against stored bytes, instruction identity, component
identity and recorded TUI frame/input provenance. Textual TUI PNGs are replays;
firefox-final.png is a separate actual Firefox screenshot. Scope is synthetic only;
Slack remains deferred. Credentials/config/provider traces are excluded.
