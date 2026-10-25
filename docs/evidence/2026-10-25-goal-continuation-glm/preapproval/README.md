# GLM-5.3 initial owner operation: preapproval checkpoint

The actual provider-reported model is `glm-5.3` on the configured single `glm-coding.glm-5-3` ordinary HTTP cohort at source `32805eb764eab2710262446e925b0ea5c3a44c08`. SSE tool-call fragments were concatenated by choice/tool index; no event-fragment count is called a tool-call count.

G2 association is PASS for this case: the owner request contains no Goal ID hint, raw response 3 selects `goal_id=goal-canary-three-results`, and the authoritative external `goal_task_links.json` maps it to `task-001`. The Task JSON does not carry that external index as an inline field.

Alpha execution is supported by the actual Edit/Read, current file and immutable verification snapshot. Both retained and current bytes are 55 bytes, SHA256 `f6bc3bec6d70ff5f11395adbe8e6ae752aba9e323a09a30ffea75b6b0458c9cc`: alpha=true, beta=false, gamma=false. No Task or Goal verdict has been issued by this observer.

The first provider loop ended publicly at response 19, but this is not an operation completion. The semantic execution is `recovering` with `gate_wait`; the journal identifies a `continuation_checkpoint`. A parked Execute `argv=["sleep","20"]` inside the isolated Docker playground still needs Gate resolution. The scalar operations table's queued row does not replace semantic execution authority. The observer cannot count a checkpoint as a model terminal failure or proceed with Task approval.

The model encountered real evaluator_unavailable, read Board's published recovery path, resubmitted once, then asked an operator through masc_ask. Automatic Task verification has not succeeded. A reported Goal measurement already exists before Task approval; that is an observation, not Goal verification or human confirmation. G3 remains unexercised.

`g2-alpha-checkpoint.json`, `gate-checkpoint.json` and the timestamped snapshot preserve selected public wire and authoritative state. `observe.py` only reads source state/SQL and writes this output directory. It never sends verdicts, links, messages, measurements or executes canary tools.

Observer incident: a separate diagnostic invocation mistakenly printed unfiltered chat-event payloads before the event type allowlist was applied. That raw output is not retained in this evidence bundle or used for conclusions. The corrected extraction first allows only boundary event types, then selects designated fields; no thought payload is retained here. Do not claim the entire observation session avoided that erroneous tool output.
