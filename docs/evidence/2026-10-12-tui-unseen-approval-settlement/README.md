# Unseen approval settlement

Base: f534aba036fd5502612b24f4ff0b2812a5a35563.

A partial reconnect log may retain a settlement before its admission. The reducer
previously discarded that event and could reopen a completed approval when its
request arrived later. Preserve observed closure identity and call correlation
without inventing the missing tool name or question. Matching repeated closure
is idempotent; conflicting correlation records a diagnostic. Other pending
admissions and their settlements remain independent. This extends prior retained
closure from matched admissions to explicit settlement observations.

Artifacts: /tmp/masc-tui-unseen-approval-settlement-20261012/.
Actual parent/current approval event arms and call lookup/update functions run
with minimal typed surroundings. Parent exits 1 because unseen settlement is
lost and late request reopens. Current exits 0 for unseen closure, absent invented
settlement label, late request refusal, repeated closure idempotence, conflicting
correlation diagnosis and unrelated admission completion. Canonical approval ID
parsing, ingress/reconnect transport and full reduction are not executed.

Two changed OCaml files passed syntax-only parsing and diff whitespace checking.
Registered state fixture is unexecuted. Full typecheck/build, provider ingress,
journal reconnect, installed runtime, UI/screenshots, CI, formal approval and
merge remain unverified. Outcome correction semantics and authoritative server
refresh remain outside this bounded closure-identity fix.

## Separate live observation

reports/chat-keeper-readonly-observation-20261012.json records a readonly
masc_keeper_status observation of the Keeper from the user screenshots. It
reported running turn 5914 with selected GLM runtime/model metadata and a tool
execution bound to that turn; the latest completed receipt belonged to the
previous turn. Recent history is a three-entry preview tail, not complete chat.
No runtime message/configuration change was issued. This does not prove these
source commits are installed, actual provider model parity, full transcript
ordering or any rendered UI. Current tool discovery exposed no terminal screenshot
or computer-control tool; no mock screenshot is substituted for actual UI proof.
