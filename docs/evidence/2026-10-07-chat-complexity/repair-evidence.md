# Repair evidence and remaining boundaries

This supplements the frozen source audit; it does not change its baseline or
turn source counterexamples into reproduced production incidents. Updated on
2026-10-07. No installed runtime or TUI has been replaced by this work.

| Finding | Repair | Evidence and remaining work |
| --- | --- | --- |
| UX1 | [#41676](https://github.com/jeong-sik/masc/pull/41676), `43339fe28c74bae6afaca7e79679ed2517e00ba9` | Queue wiring 122/122 passed on this head. Activity 17/17 passed on earlier `d26ea60849b5de2a8a257a91cde8df277b36412c`; queue visibility PTY passed on `161566fad72cd620e34895dfead9872146a4f11b`. Runtime application remains unverified. |
| F1/F2 | [#41688](https://github.com/jeong-sik/masc/pull/41688), `49b559422af7f281b49a6ca8505558f57cb618c6` | Independent source review PASS against `43339fe28c74bae6afaca7e79679ed2517e00ba9`; transition fixtures added; descendant queue and autonomous-journal suites passed at the recorded UI integration SHAs below. |
| F3 | [#41696](https://github.com/jeong-sik/masc/pull/41696), `7c25862a4fc0e8c2024cf547344c8a7060d21dc2` | Independent source review PASS against `3ec6f738f937992ba827614620605fec78b0ba41`. Shared projection and typed viewport origins also repair history/journal replacement, workspace identity, repeated frame compensation, long-answer match placement and journal-only anchoring. Executed UI integration passed on `07027ede31420352372350a6431bce3a1c35b8c0`; see the precise suite scopes below. |
| F4 | [#41695](https://github.com/jeong-sik/masc/pull/41695), implementation `fcc8054f0cb0ad017862599d70b2957d1867abf7` | Independent source review PASS against `c5a5358419d97ebd590a690486585de0f4c6c92c`; `b4822afb3f11d028ac1a9fbbcf521e5bcd932611` only replaces provisional changelog files. Replay/handoff 17/17 passed at `b4822afb3f11d028ac1a9fbbcf521e5bcd932611`; wire-terminal 14/14 passed after fixture setup repair at `3ec6f738f937992ba827614620605fec78b0ba41`. |
| F5 | [#41697](https://github.com/jeong-sik/masc/pull/41697), `07027ede31420352372350a6431bce3a1c35b8c0` | Independent integrated source review PASS against F3 `7c25862a4fc0e8c2024cf547344c8a7060d21dc2`. A flat final string lacks canonical block mapping; the repair preserves observed order and labels separate final authority, rather than inferring a mapping from text. Executed UI integration passed on `07027ede31420352372350a6431bce3a1c35b8c0`; see the precise suite scopes below. |
| F6 | [#41691](https://github.com/jeong-sik/masc/pull/41691), `c5a5358419d97ebd590a690486585de0f4c6c92c` | Independent source review PASS against `49b559422af7f281b49a6ca8505558f57cb618c6`; start/sparse usage and scope-aware provider-start fixtures passed in the descendant decoder/log/transcript suites recorded below. |
| F7 (found during repair) | #41695 scopes direct-operation subscribers and terminal accounting by canonical runtime base, Keeper and operation ID | Two Keeper names and two runtime roots may legitimately reuse operation IDs. The direct tables previously conflated those identities. Independent source review PASS; all 14 wire-terminal cases passed at `3ec6f738f937992ba827614620605fec78b0ba41`. General observer-bus isolation is addressed separately in #41698. |

## Executed development checks

- [Run 37609387361](https://github.com/jeong-sik/masc/actions/runs/37609387361):
  queue visibility PTY passed, then OCaml fixture compilation failed because the
  renderer interface omitted two used projection exports. Fixed in `d26ea60849`.
- [Run 37611962142](https://github.com/jeong-sik/masc/actions/runs/37611962142):
  activity 17/17; queue wiring 121/122. The remaining assertion expected an old
  tool heading, although the new heading deliberately identifies `TOOLS`.
- [Run 37614837619](https://github.com/jeong-sik/masc/actions/runs/37614837619):
  queue wiring 122/122 on `43339fe28c74bae6afaca7e79679ed2517e00ba9`.

These scopes and SHAs are distinct. No full RC, provider session, deployment,
GitHub approval or merge is established by these checks. External coding agents
did not run local Dune builds.

Additional server execution: [run 37616731656](https://github.com/jeong-sik/masc/actions/runs/37616731656)
passed replay/handoff 17/17 at `b4822afb3f11d028ac1a9fbbcf521e5bcd932611`.
Wire terminal passed 13/14; its two-root case failed during setup because the
shared fixture creates millisecond-named directories. The distinct child-root
repair is `3ec6f738f937992ba827614620605fec78b0ba41`, independently source-reviewed.
[Wire rerun 37617447245](https://github.com/jeong-sik/masc/actions/runs/37617447245)
and [combined UI run 37617448935](https://github.com/jeong-sik/masc/actions/runs/37617448935)
were in progress at the earlier publication boundary. Completed results are recorded below. The UI run selected 11 changed
chat/layout suites on leaf `2801c8de19811664add67f68ecad1ec396c116c3`.

## Projection complexity after repair

The same source-AST analyzer was run on that leaf's renderer, layout and
transcript; raw output is `repaired-projection-metrics.jsonl` and scope metadata
is `repaired-projection-metrics-summary.json`. `render_keeper_message` is now
870 lines with decision score 128 (baseline 1,483 / 220), while the extracted
shared `keeper_message_projection` is 501 lines / 75. Search is 53 lines / 9;
physical-row matching is 43 / 14. These are not aggregate complexity reductions
or executed coverage. The useful change is that drawing, search and scroll
measurement now share the same conversation and typed origins.

## Observer boundary found during repair

The global observer bus did not preserve runtime root authority. In a process
hosting multiple runtime states, A's operation notification could reach B's same
Keeper pane. TUI re-queries its own journal rather than folding the foreign
body; `Unknown_operation` could then poison its unavailable-source tracking and
block a later legitimate B operation using that ID. Dashboard WebSocket code
also consumes the raw operation payload, so there is a separate direct body
mixing path. This is a source witness, not an observed single-root incident.

The repair in #41698 preserves authority at typed publication, subscriber and replay
boundaries, including external WebSocket/gRPC delivery. General global broadcasts
remain outside that scoped repair. The gRPC subscriber occurrence ID also used
agent name plus milliseconds; simultaneous subscriptions could replace one
another before scope filtering. Its repair uses process-unique occurrence IDs.

## Latest executed UI repair boundary

[Run 37620305202](https://github.com/jeong-sik/masc/actions/runs/37620305202)
passed on `07027ede31420352372350a6431bce3a1c35b8c0`: search projection 10/10,
transcript 108/108, queue wiring 124/124 and queue visibility PTY. The PTY builds
and runs the real TUI against controlled HTTP fixtures, including accepted input,
transport loss, replay, run start and terminal state. It is not an installed-runtime
or actual provider-session observation.

Before that run, [37618480879](https://github.com/jeong-sik/masc/actions/runs/37618480879)
passed nine of eleven selected UI suites on `e511b85db2d134f1081375e6b395398db7d0cbb2`.
Its four failing cases were then investigated individually:

- Search's final-reply assertion assumed in-place replacement even for multiple
  observed stretches. It now checks separate final authority and the surviving
  observed origin when repeating search.
- A search pinned at scroll zero could restore a positive scroll after new output
  arrived, but the first frame budgeted its notice/menu from the old stored zero.
  The resulting one-row shift was a real production defect. `6e350fb5d1` uses the
  same restored scroll in layout, status/menu budgeting and notice drawing;
  `7c25862a4f` declares the fixture's new direct input dependency.
- The legend fixture hard-coded six outcomes despite the native outcomes already
  being present. The numeric counts were removed; each displayed legend label
  remains checked.
- A native-tool fixture asked for a folded summary of a single call, which is
  intentionally shown in full. It now supplies two distinct native occurrences
  and checks their real compact summary without inventing execution receipts.

The earlier compile-only failure in run 37617448935 was an orphan private helper
left after sharing the projection. `bacfc5da65` removes it. An accidental stale-ref
run 37618341279 after a failed push was requested for cancellation and is not
repair evidence. No passing result is inferred from either run.

The wire-terminal rerun [37617447245](https://github.com/jeong-sik/masc/actions/runs/37617447245)
passed all 14 cases at `3ec6f738f937992ba827614620605fec78b0ba41`.

## Observer repair publication and remaining execution

[#41698](https://github.com/jeong-sik/masc/pull/41698) contains the runtime-scoped
observer repair. Current published integration head is
`146dffa4c7cac56c150017e3bd8302f024fe443b`; its parent is the UI repair head above.
Its first three-suite run (37619579544) stopped at a fixture calling a private WS
function. `a4d1deb42e` switches to the public JSON-RPC dispatcher, checking both
foreign-root rejection and bound-root authentication. The corresponding SSE,
WebSocket and gRPC rerun [37621300426](https://github.com/jeong-sik/masc/actions/runs/37621300426)
passed all three suites on that head: SSE 22/22, WebSocket 64/64 and gRPC 31/31. No provider-session or deployed-runtime verdict follows.

The implementation's prior source review passed at `b188882ee9`. Independent source review subsequently passed the integrated observer head `146dffa4c7cac56c150017e3bd8302f024fe443b`, final-response head `07027ede31420352372350a6431bce3a1c35b8c0` and search head `7c25862a4fc0e8c2024cf547344c8a7060d21dc2`. Native tool terminal facts were subsequently repaired and verified as recorded below.

## Native outcomes and provider activity

[#41702](https://github.com/jeong-sik/masc/pull/41702), head
`3df8207c0c1e3fd7ed216d6889868a539a4a51a6`, preserves Codex completion status
and optional exit code, Claude's optional error flag, and Antigravity Done/Error.
The report retains exact native occurrence authority and never creates a MASC
execution receipt. Independent source review PASS against
`146dffa4c7cac56c150017e3bd8302f024fe443b`; complete binary diff SHA256
`93239461bdcb6dd167492c1f5106dc239b1c22f46f41e4ec956283f7d568dd37`.
Review exposed and resolved a P2 where duplicate or variant-incompatible result
fields silently became normal observations.

[Run 37628976492](https://github.com/jeong-sik/masc/actions/runs/37628976492)
passed on that head: Codex 150, Claude adapter 54, Claude runtime 85, Antigravity
59, native boundary 6, journal codec 26, live decoder 39, log 17, transcript 108.
The provider cases use controlled native protocol fixtures and adapters through
the production bridge, journal, SSE, and TUI projection. No live provider session
or installed binary change is established.

[#41704](https://github.com/jeong-sik/masc/pull/41704) separately retains provider
response-stop events so a still-running Keeper turn no longer shows stale
STREAMING/THINKING. Independent source review passed
`f31bb3c28783ff4e7abea78fd1b956a1bd187afc` against #41702 after correcting a
missing-value decode P2; complete diff SHA256
`60596e99ece45b36b2256e149bd910d1ad744aca832fe148e245a3b8e7b5a924`.
The first focused run [37631318907](https://github.com/jeong-sik/masc/actions/runs/37631318907)
reached all four TUI activity states but failed during fixture exit and on a
missing test dependency. The repaired scenario passed in
[37633584018](https://github.com/jeong-sik/masc/actions/runs/37633584018) at
`13eeb43f91fe4a05eef311714ffdb82db9941de8`; its four actual terminal frames are
in [model-phase-pty-frames.json](model-phase-pty-frames.json). That run still
failed overall because an OCaml fixture referenced private `T.progress_text`.
`f31bb3c287` reads the public `status_rows` projection instead. No complete
phase-suite PASS is inferred from the PTY result.

## Progress and child metadata repair boundaries

[#41716](https://github.com/jeong-sik/masc/pull/41716) preserves Codex command
output activity and redacted MCP progress with exact active tool authority.
[37633910236](https://github.com/jeong-sik/masc/actions/runs/37633910236) passed
at initial head `94176ce6f70f672c9ef4b4bc6b88b8ecc3cec738`: Codex 152,
native progress 4, native boundary 6 and journal codec 26. Independent review
nevertheless found a P1: a side progress observation finalized text redaction,
allowing pieces of a split secret to be reassembled from published fragments.
The original fixture bypassed the actual Scoped redactor, so those passing
tests did not exercise that boundary.

`1c0c6c6e83f609e26a7e5ad27942e7afe406c42a` removes progress-only finalization
and makes the shared fixture use the actual Scoped redactor. Text and Thinking
cases now span progress between a configured secret's prefix and suffix through
the direct Scoped projection and an actual autonomous on-disk journal. Independent
source review PASS against `08cc89a954f266b0ff1807fe3d26614c0a431768`, full diff
SHA256 `ed1e9bafd6fc2455f2d46b09c63a8bab640fe0d0ff66750f889517e89fd7ce2e`.
Execution of this P1 repair remains unverified here. Existing native completion
and unrelated block events still finalize held content; that separate defect
requires content ownership and real provider content-end evidence.

[#41719](https://github.com/jeong-sik/masc/pull/41719) prevents Claude child
tool envelopes from overwriting root model and latest-input usage. Installed
Claude 2.1.292 schema and serializers confirm the required parent field and
preserved child metadata. Source review PASS for its own delta at
`98e4c725165a34c8a6d08f1a8fc8403d0d475426` against `94176ce6f70f672c9ef4b4bc6b88b8ecc3cec738`,
full diff SHA256 `aef9c99209b0b55d7c40fa988b6606f453bcc407de046ad539e55952a8ada63a`.
Its focused run [37634890474](https://github.com/jeong-sik/masc/actions/runs/37634890474)
was pending at this evidence boundary. This does not qualify child tool identity
or progress, and does not enable child text forwarding. The source verdict
does not clear the independently found ancestor progress defect.

## Challenged leads

`Cursor_refused` did not establish an infinite refusal loop. Each
`read_whole_journal` starts its byte position at `Journal.first_row`, and the
server accepts offset zero with the retained event-sequence cursor. Replacing a
journal while reusing old sequence numbers would need an explicit generation
contract; that is not the ordinary append-only writer path, and simply reading
the whole journal would not bypass the held event deduplication anyway.

## Still outside the evidence

- End-to-end provider sessions for Codex, Claude Code, Antigravity and GLM Coding.
- Capability gaps documented in the vendor audit, including native tool output
  and result content, child-tool attribution and unsupported reasoning events.
- Canonical content-block provenance for final text, rather than a flat reply.
- Viewport source-position preservation under terminal resize and Markdown
  reflow; a physical body-row ordinal alone cannot prove it.
- Broadcast and asynchronous event interleavings beyond the focused fixtures.
- Installed artifact identity and actual TUI behavior after application.

The goal remains active. Source review, executed fixtures and deployed behavior
must continue to be reported separately.
