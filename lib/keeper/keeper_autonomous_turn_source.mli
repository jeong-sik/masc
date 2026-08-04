(** Keeper_autonomous_turn_source — dashboard read model for autonomous
    keeper turns.

    An autonomous turn leaves no row in {!Keeper_chat_store}. That is a
    decision, not a gap: RFC-0351 §5 (#25462) keeps the wake marker out of
    the durable transcript after one keeper accumulated the same 147B
    message 359 times, and [Keeper_types_support.turn_effect_record]
    classifies a tool-less wake as [Inert_autonomous_turn] because
    persisting idle prose grows the transcript and then teaches the
    librarian about that idleness.

    The bodies do exist. [Keeper_agent_run] writes one raw-trace file per
    turn under [.masc/keepers/<name>/raw-traces/]; until this module there
    was no reader for it. This projects that store so the dashboard chat
    can render autonomous turns beside the direct conversation.

    Read-only and additive by construction: nothing here writes to the
    chat store, so a keeper's [recent_direct_conversation] observation is
    byte-identical with and without this module. The feedback loop
    RFC-0351 closed stays closed — the dashboard reads the trace, the
    keeper does not read it back.

    Reach is bounded by retention, not by this module:
    {!Keeper_types_support.raw_trace_retained_turn_files} files per
    keeper. Turns older than that keep only their turn-record metadata
    (tokens, latency); their bodies are already deleted. *)

type block =
  | Thinking of string
  | Text of string
  | Tool_use of {
      name : string;
      input : Yojson.Safe.t option;
    }
      (** Sourced from the tool-execution record, not the assistant
          [tool_use] block: the execution record carries the tool name and
          input the runtime actually dispatched. *)
(** One rendered element of a turn, in the order the trace recorded it. *)

type turn = {
  turn_id : string;
      (** Raw-trace file basename — unique per turn and stable for the
          file's lifetime. The dashboard keys rows on it because the
          raw-trace store carries no [turn_ref] (RFC-0358 adds one). *)
  started_at : float;
  finished_at : float option;
  model : string option;
  stop_reason : string option;
  blocks : block list;
  final_text : string option;
      (** The run's terminal text, kept separate from {!blocks} because a
          run can finish without one (cancelled, tool-only, or errored). *)
}

val default_limit : int
(** Newest raw-trace files inspected per {!load_recent} call when the
    caller passes no [limit]. Bounds the per-request parse cost: a keeper
    at the retention ceiling holds far more turn files than one chat
    transcript should render. *)

val load_recent :
  config:Workspace.config ->
  keeper_name:string ->
  ?limit:int ->
  ?since:float ->
  unit ->
  turn list
(** [load_recent ~config ~keeper_name ()] returns [keeper_name]'s
    autonomous turns oldest-first, drawn from the newest [limit] raw-trace
    files (default {!default_limit}). [since] keeps only turns that
    started strictly after that timestamp.

    Direct [masc_keeper_msg] turns share this store — [Keeper_turn] runs
    them through the same [Keeper_agent_run.run_turn] — and are excluded
    via {!Keeper_unified_prompt.is_autonomous_wake_prompt}. They are
    already persisted in the chat store, so emitting them here would
    render them twice.

    Total: an unreadable directory yields [[]], and a file that fails to
    parse is logged and skipped. This runs on the dashboard chat read
    path, which must not fail because one turn file is corrupt. *)
