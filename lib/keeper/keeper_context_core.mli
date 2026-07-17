(** Keeper working-context primitives — token counting, message
    history, OAS checkpoint conversion, JSONL persistence.

    Final selective-exposure .mli of the keeper subsystem (PR#3
    series): the largest module in lib/keeper/ at 1401 lines.
    Public API surfaces 47 external callers + closely related
    types; internal sanitizers, JSONL classifiers, and message
    repair helpers stay private. *)

type working_context = Keeper_types.working_context
type session_context = Keeper_types.session_context

val message_count : working_context -> int
val max_tokens_of_context : working_context -> int

(** Replace the working-context's [max_tokens]; mirrors the value
    into [checkpoint.max_total_tokens]. *)
val with_max_tokens : working_context -> int -> working_context

(** Re-export of [Agent_sdk.Types.text_of_message]. *)
val text_of_message : Agent_sdk.Types.message -> string

(** {1 Working-context construction & mutation} *)

(** Construct a fresh working context with the given system prompt
    and token budget.

    [~eio:true] selects the OAS context backend required when the context can
    be touched by Eio fibers. Use [~eio:false] only for synchronous tests or
    serialization fixtures. *)
val create : eio:bool -> system_prompt:string -> max_tokens:int -> working_context

val set_system_prompt :
  working_context -> system_prompt:string -> working_context

val append : working_context -> Agent_sdk.Types.message -> working_context
val append_many : working_context -> Agent_sdk.Types.message list -> working_context

(** Push the exact working-context message count into the OAS [Context.t]
    (Session scope). Provider token usage is response telemetry and is not a
    measure of the current checkpoint's context size. *)
val sync_oas_context : working_context -> working_context

(** {1 Working-context projections} *)

val checkpoint_of_context : working_context -> Agent_sdk.Checkpoint.t
val resume_checkpoint_of_context : working_context -> Agent_sdk.Checkpoint.t
(** Project [working_context] to the checkpoint passed to OAS resume without
    rewriting, trimming, or stubbing message content. *)

val oas_context_of_context : working_context -> Agent_sdk.Context.t
val system_prompt_of_context : working_context -> string
val messages_of_context : working_context -> Agent_sdk.Types.message list

(** {1 Role / message JSON} *)

val role_to_string : Agent_sdk.Types.role -> string

(** [Some] only for the four wire-format names; callers must
    handle [None] explicitly (#8623). *)
val role_of_string_opt : string -> Agent_sdk.Types.role option

val message_to_json : Agent_sdk.Types.message -> Yojson.Safe.t
val message_of_json : Yojson.Safe.t -> Agent_sdk.Types.message

(** Project a JSONL entry to its visible-text rendering used by
    history classification. *)
val text_of_history_jsonl_json : Yojson.Safe.t -> string

type tool_pair_repair_stats =
  { dropped_tool_uses : int
  ; dropped_tool_results : int
  ; dropped_tool_use_samples : (string * string) list
  ; dropped_tool_result_ids : string list
  }

val tool_pair_repair_stats_changed : tool_pair_repair_stats -> bool

(** {1 Context (de)serialization} *)

val serialize_context : working_context -> string
val serialized_bytes : working_context -> int
(** Exact byte length of {!serialize_context}. This is structural observation,
    not a token estimate or provider context-window admission signal. *)
val deserialize_context : eio:bool -> string -> max_tokens:int -> working_context
val context_to_json : working_context -> Yojson.Safe.t

(** {1 Session lifecycle} *)

val create_session : session_id:string -> base_dir:string -> session_context

(** {1 History migration} *)

(** Stats returned by [migrate_session_history_logs]. *)
type history_migration_stats =
  { moved_lines : int
  ; dropped_lines : int
  ; kept_lines : int
  ; malformed_lines : int
  }

(** [true] iff [text] looks like a Current World State system
    context block (used to drop legacy world-state echoes from
    history.jsonl). *)
val has_world_state_signature : string -> bool

(** Move every internal-history entry from [history.jsonl] to
    [history.internal.jsonl], drop world-state echoes, and dedupe
    the merged internal log. *)
val migrate_session_history_logs :
  session_dir:string -> history_migration_stats

(** {1 JSONL persistence} *)

(** Append [msg] to the keeper's history JSONL, choosing
    [history.jsonl] / [history.internal.jsonl] from [source]. *)
val persist_message :
  ?source:string -> session_context -> Agent_sdk.Types.message -> unit

(** {1 Re-exports from Inference_utils} *)

val timed : (unit -> 'a) -> 'a * int
val zero_usage : Agent_sdk.Types.api_usage
val usage_of_response :
  Agent_sdk_response.api_response -> Agent_sdk.Types.api_usage
val total_tokens : Agent_sdk.Types.api_usage -> int

(** Save the current working context as a generation-tagged OAS checkpoint.
    Message order and typed content are preserved exactly. No implicit context
    reduction is performed at this boundary. *)
val save_oas_checkpoint :
  multimodal_policy:Keeper_types_profile.multimodal_policy ->
  keeper_name:string ->
  session:session_context ->
  agent_name:string ->
  ctx:working_context ->
  generation:int ->
  (Agent_sdk.Checkpoint.t, string) result
(** [multimodal_policy]/[keeper_name] gate RFC §2.3 site-2 image eviction at the
    checkpoint write boundary (Store_only); required so every write path is
    compiler-forced to declare its policy (N-of-M closure). *)

val save_oas_checkpoint_classified :
  multimodal_policy:Keeper_types_profile.multimodal_policy ->
  keeper_name:string ->
  session:session_context ->
  agent_name:string ->
  ctx:working_context ->
  generation:int ->
  ( Agent_sdk.Checkpoint.t * Keeper_checkpoint_store.save_oas_outcome
  , string )
  result

(** {1 OAS checkpoint inspection} *)

val checkpoint_generation : Agent_sdk.Checkpoint.t -> fallback:int -> int
val checkpoint_max_tokens : Agent_sdk.Checkpoint.t -> fallback:int -> int

(** Project an OAS checkpoint to a working context without rewriting its
    messages. *)
val context_of_oas_checkpoint :
  Agent_sdk.Checkpoint.t ->
  primary_model_max_tokens:int ->
  working_context

(** Load the canonical OAS checkpoint for a given
    [trace_id]. Returns the session plus the recovered
    working_context (or [None] when nothing was found). *)
val load_context_from_checkpoint :
  trace_id:string ->
  primary_model_max_tokens:int ->
  base_dir:string ->
  session_context * working_context option

(** {1 Checkpoint patching} *)

(** Patch the last assistant message in [cp] with a unified [session_id] and
    visible response text. *)
val patch_checkpoint_last_assistant :
  Agent_sdk.Checkpoint.t ->
  session_id:string ->
  response_text:string ->
  Agent_sdk.Checkpoint.t

(** {1 Diagnostics} *)

val log_keeper_exn : label:string -> exn -> unit
