(** Keeper working-context primitives — token counting, message
    history, AGENT_CORE checkpoint conversion, JSONL persistence.

    Final selective-exposure .mli of the keeper subsystem (PR#3
    series): the largest module in lib/keeper/ at 1401 lines.
    Public API surfaces 47 external callers + closely related
    types; internal sanitizers, JSONL classifiers, and message
    repair helpers stay private. *)

type working_context = Keeper_types.working_context
type session_context = Keeper_types.session_context

val message_count : working_context -> int

(** Re-export of [Agent_core.Types.text_of_message]. *)
val text_of_message : Agent_core.Types.message -> string

(** {1 Working-context construction & mutation} *)

(** Construct a fresh working context with the given system prompt.

    [~eio:true] selects the AGENT_CORE context backend required when the context can
    be touched by Eio fibers. Use [~eio:false] only for synchronous tests or
    serialization fixtures. *)
val create : eio:bool -> system_prompt:string -> working_context

val set_system_prompt :
  working_context -> system_prompt:string -> working_context

val append : working_context -> Agent_core.Types.message -> working_context
val append_many : working_context -> Agent_core.Types.message list -> working_context

(** Push the exact working-context message count into the AGENT_CORE [Context.t]
    (Session scope). Provider token usage is response telemetry and is not a
    measure of the current checkpoint's context size. *)
val sync_agent_core_context : working_context -> working_context

(** {1 Working-context projections} *)

val checkpoint_of_context : working_context -> Agent_core.Checkpoint.t
val resume_checkpoint_of_context : working_context -> Agent_core.Checkpoint.t
(** Project [working_context] to the checkpoint passed to AGENT_CORE resume without
    rewriting, trimming, or stubbing message content. *)

val agent_core_context_of_context : working_context -> Agent_core.Context.t
val system_prompt_of_context : working_context -> string
val messages_of_context : working_context -> Agent_core.Types.message list

(** {1 Role / message JSON} *)

val role_to_string : Agent_core.Types.role -> string

(** [Some] only for the four wire-format names; callers must
    handle [None] explicitly (#8623). *)
val role_of_string_opt : string -> Agent_core.Types.role option

val message_to_json : Agent_core.Types.message -> Yojson.Safe.t

val message_measurer : unit -> (Agent_core.Types.message -> int)
(** A measurer of how many bytes {!message_to_json} serializes a message to,
    as [Yojson.Safe.to_string] would count them, without building the string.
    One measurer owns one reused buffer and belongs to one walk. *)
val message_of_json : Yojson.Safe.t -> Agent_core.Types.message

(** Project a JSONL entry to its visible-text rendering used by
    history classification. *)
val text_of_history_jsonl_json : Yojson.Safe.t -> string

(** {1 Session lifecycle} *)

val create_session : session_id:string -> base_dir:string -> session_context

(** {1 JSONL persistence} *)

(** Append [msg] to the keeper's history JSONL, choosing
    [history.jsonl] / [history.internal.jsonl] from [source]. The line names
    the turn that wrote it ([turn_ref]). *)
val persist_message :
  keeper_name:string ->
  turn_ref:Ids.Turn_ref.t ->
  ?source:string ->
  session_context ->
  Agent_core.Types.message ->
  unit

(** Append one tool observation (canonical name, outcome) for [turn_ref] to
    [history.internal.jsonl]. *)
val persist_tool_observation :
  keeper_name:string ->
  turn_ref:Ids.Turn_ref.t ->
  session_context ->
  tool_name:string ->
  outcome:Tool_result.tool_call_outcome ->
  unit

type 'persistence_error checkpoint_write_error =
  | Tool_history_invalid of Keeper_transcript_unit.structural_error
  | Persistence_error of 'persistence_error

val checkpoint_write_error_to_string
  :  persistence_error_to_string:('persistence_error -> string)
  -> 'persistence_error checkpoint_write_error
  -> string

(** Save the current working context as a generation-tagged AGENT_CORE checkpoint.
    Message order and typed content are preserved exactly. A structurally open
    ToolUse suffix is valid and remains exact; malformed completed protocol
    structure is rejected as [Tool_history_invalid] before any store call. No
    repair, synthetic ToolResult, or implicit context reduction occurs here. *)
val save_agent_core_checkpoint :
  runtime_id:string ->
  keeper_name:string ->
  session:session_context ->
  agent_name:string ->
  ctx:working_context ->
  (Agent_core.Checkpoint.t, string checkpoint_write_error) result
(** [runtime_id]/[keeper_name] gate RFC §2.3 site-2 image eviction at the
    checkpoint write boundary (Store_only); required so every write path is
    compiler-forced to name the runtime it persists for (N-of-M closure). *)

(** {!save_agent_core_checkpoint} with the store's verdict kept: [Saved] when
    this checkpoint became the canonical one, [Stale_noop] when a newer writer
    already owns it and nothing was written. {!save_agent_core_checkpoint}
    answers [Ok] for both, so a caller that reports what it stored uses this
    one. *)
val save_agent_core_checkpoint_classified :
  runtime_id:string ->
  keeper_name:string ->
  session:session_context ->
  agent_name:string ->
  ctx:working_context ->
  ( Agent_core.Checkpoint.t * Keeper_checkpoint_store.save_agent_core_outcome
  , string checkpoint_write_error )
  result

(** {1 AGENT_CORE checkpoint inspection} *)


(** Project an AGENT_CORE checkpoint to a working context without rewriting its
    messages. *)
val context_of_agent_core_checkpoint :
  Agent_core.Checkpoint.t -> working_context

(** What a checkpoint load found. *)
type checkpoint_load =
  | Checkpoint_loaded of working_context
  | Checkpoint_absent  (** No checkpoint is saved for the trace. *)
  | Checkpoint_unread of Keeper_checkpoint_store.checkpoint_load_error
      (** The load failed for any other reason: a superseded version, a parse,
          store, I/O or agent-core error. The saved history was not seen and
          may still hold what it held. *)

(** Load the canonical AGENT_CORE checkpoint of [trace_id] and say which of the
    three it was. Every failure is logged and counted here. *)
val load_context_from_checkpoint_classified :
  trace_id:string ->
  base_dir:string ->
  session_context * checkpoint_load

(** Optional projection for callers acting only on a loaded context. [None]
    covers absence and a diagnosed failure; it cannot authorize a fresh turn.
    Turn execution uses {!load_context_from_checkpoint_classified}. *)
val load_context_from_checkpoint :
  trace_id:string ->
  base_dir:string ->
  session_context * working_context option

(** {1 Checkpoint patching} *)

(** Patch the last assistant message in [cp] with a unified [session_id] and
    visible response text. *)
val patch_checkpoint_last_assistant :
  Agent_core.Checkpoint.t ->
  session_id:string ->
  response_text:string ->
  Agent_core.Checkpoint.t

(** {1 Diagnostics} *)

val log_keeper_exn : label:string -> exn -> unit
