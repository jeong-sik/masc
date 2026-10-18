# Ask follow-up source stream

Source baseline: `55b0a9394cfcec753a8f8f92c83dbbf06f62e21d`.
Scope: server source publication, one-request SSE transport and typed receiver.
The current Questions pane still uses the aggregate reader; its progressive
state/rendering integration is the next layer, not completed by this change.

| Boundary | Before | After |
| --- | --- | --- |
| Reaction, Tool and original Task observations | Independent reads, but HTTP waits for the full join | Opt-in request emits each source as it settles |
| Canonical answer capture | One capture for the aggregate | One capture shared by stream identity and all source callbacks |
| Early Task result while a peer is pending | Available only to the server until the aggregate returns | Typed Task source frame can reach the receiver before the peer finishes |
| Other sources not yet delivered | Aggregate has no early response | No invented unavailable/empty placeholders; the source frame names only its own data |
| Stream completion | HTTP response ends after aggregate | Single start, all exact sources once, unchanged-identity completion; EOF alone is insufficient |
| Invalid/duplicate/foreign frame | No source-stream reader | Strict protocol rejection; abort transport rather than wait through an invalid stream |
| Existing aggregate request | Joined source result | Same aggregate projection, using the same source encoders/decoders |
| TUI first-result visibility | Aggregate read drives the pane | Still aggregate until the next state/rendering layer is connected |

Request `GET /api/v1/keepers/asks` with one `name`, one `answer_progress_for`,
`answer_progress_stream=true` and the existing expected-workspace precondition.
The strict canonical Ask rows are read once. Canonical answer validation precedes
the start frame and all source reads. An invalid stream selection is rejected;
unready workspace or missing/nonanswered canonical input never opens a source
stream. No question/answer text is sent in these frames.

Each SSE frame carries workspace readiness, Keeper, original Ask, canonical
answer time and stimulus identity. Start precedes sources; `reaction_evidence`,
`tool_actions` and `linked_task` use the same private-content-free projection as
the aggregate. Publication occurs after that source read and before the full
join. Complete follows all callbacks; it means read delivery, never answer
consumption, model start, Task progress or whole-work completion.

The HTTP writer serializes frames through the existing owned streaming writer.
Disconnect or callback failure cancels the read scope and joins common executor
cleanup; source work is read-only and is never repeated as an effect. The stream
closes in the request scope. No process-side result registry, second answer
store, duplicate per-source Ask scan, new timer or numerical runtime cap exists.

The client uses the common authenticated streaming transport and SSE parser.
Pure frame decoding uses the shared CPU executor policy; HTTP ownership and
event delivery stay in the caller. The protocol state requires one canonical
start, every typed source once, and matching completion. Duplicate/foreign or
premature terminal frames abort; disconnected/truncated EOF cannot become a
successful read. Earlier valid source events remain observations, not an
invented aggregate. Common executor inline cases and existing transport idle
policy remain unchanged. No automatic reconnect/replay is introduced.

Two new scenarios and one expanded HTTP scenario are authored and unexecuted.
The backend case publishes a real original Task while a peer callback is held,
then joins without creating a wake. The protocol case accepts independent source
order and refuses duplicate, changed-answer, foreign-Keeper, premature-terminal,
truncated and post-completion sequences. The HTTP case traverses the real route
and source decoders using close-framed HTTP/1.0, plus malformed stream selection.
They are data/protocol cases, not wording/layout/PTY assertions.

Parser/source checks do not establish typing or executed behavior. No scenario,
CI, native/model run, installation/restart, live transport, TUI frame, paint or
latency comparison was executed. In particular, the new stream is not yet the
Questions pane's active read path. The next layer must retain per-source pending,
last-observed and failed states under original workspace/request/answer ownership,
preserving completed source facts if another source or transport fails.

Matched Before/After must record source observation, client admission and paint
separately and retain failed/cancelled/interrupted/unfinished requests. The full
goal also retains Ask-to-original-Task useful execution, preparation attribution,
Composition/held-job scenarios, remaining editor I/O and runtime/UI proof.
