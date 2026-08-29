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
val message_of_json : Yojson.Safe.t -> Agent_core.Types.message

(** Project a JSONL entry to its visible-text rendering used by
    history classification. *)
val text_of_history_jsonl_json : Yojson.Safe.t -> string

(** {1 Context (de)serialization} *)

val serialize_context : working_context -> string
val serialized_bytes : working_context -> int
(** Exact byte length of {!serialize_context}. This is structural observation,
    not a token estimate or provider context-window admission signal. *)

(** {1 Session lifecycle} *)

val create_session : session_id:string -> base_dir:string -> session_context

(** {1 JSONL persistence} *)

(** Append [msg] to the keeper's history JSONL, choosing
    [history.jsonl] / [history.internal.jsonl] from [source]. *)
val persist_message :
  ?source:string -> session_context -> Agent_core.Types.message -> unit

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


(** Build and conditionally publish the same canonical checkpoint payload as
    {!save_agent_core_checkpoint_classified}, but only while the durable source still
    has [expected_source_ref]. Equal-turn content changes are rejected by the
    checkpoint store's exact byte-identity CAS. *)

module For_testing : sig
  val save_agent_core_checkpoint_if_source_with_history :
    save_agent_core_history:
      (session_dir:string -> Agent_core.Checkpoint.t -> unit) ->
    runtime_id:string ->
    keeper_name:string ->
    session:session_context ->
    agent_name:string ->
    ctx:working_context ->
    expected_source_ref:Keeper_checkpoint_ref.t ->
    ( Agent_core.Checkpoint.t * Keeper_checkpoint_store.checkpoint_installation
    , Keeper_checkpoint_store.checkpoint_cas_error checkpoint_write_error )
    result
end

(** {1 AGENT_CORE checkpoint inspection} *)


(** Project an AGENT_CORE checkpoint to a working context without rewriting its
    messages. *)
val context_of_agent_core_checkpoint :
  Agent_core.Checkpoint.t -> working_context

(** Load the canonical AGENT_CORE checkpoint for a given
    [trace_id]. Returns the session plus the recovered
    working_context (or [None] when nothing was found). *)
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
