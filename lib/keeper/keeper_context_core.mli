(** Keeper working-context primitives — token counting, message
    history, OAS checkpoint conversion, JSONL persistence.

    Final selective-exposure .mli of the keeper subsystem (PR#3
    series): the largest module in lib/keeper/ at 1401 lines.
    Public API surfaces 47 external callers + closely related
    types; internal sanitizers, JSONL classifiers, and message
    repair helpers stay private. *)

type working_context = Keeper_types.working_context
type checkpoint = Keeper_types.checkpoint
type session_context = Keeper_types.session_context

(** Default cap on checkpoint messages persisted at save-time. *)
val default_max_checkpoint_messages : int

(** {1 Token counting} *)

(** Token count of a single OAS message. *)
val msg_tokens : Oas.Types.message -> int

(** Total tokens across [system_prompt] + every message. *)
val count_tokens : string -> Oas.Types.message list -> int

val token_count : working_context -> int
val message_count : working_context -> int
val context_ratio : working_context -> float
val max_tokens_of_context : working_context -> int

(** Replace the working-context's [max_tokens]; mirrors the value
    into [checkpoint.max_total_tokens]. *)
val with_max_tokens : working_context -> int -> working_context

(** Re-export of [Oas.Types.text_of_message]. *)
val text_of_message : Oas.Types.message -> string

(** {1 Working-context construction & mutation} *)

(** Construct a fresh working context with the given system prompt
    and token budget. *)
val create : system_prompt:string -> max_tokens:int -> working_context

val set_system_prompt :
  working_context -> system_prompt:string -> working_context

val append : working_context -> Oas.Types.message -> working_context
val append_many : working_context -> Oas.Types.message list -> working_context

(** Push the working-context's derived counters into the OAS
    [Context.t] (Session scope). *)
val sync_oas_context : working_context -> working_context

(** {1 Working-context projections} *)

val checkpoint_of_context : working_context -> Oas.Checkpoint.t
val oas_context_of_context : working_context -> Oas.Context.t
val system_prompt_of_context : working_context -> string
val messages_of_context : working_context -> Oas.Types.message list

(** {1 Role / message JSON} *)

val role_to_string : Oas.Types.role -> string

(** [Some] only for the four wire-format names; callers must
    handle [None] explicitly (#8623). *)
val role_of_string_opt : string -> Oas.Types.role option

(** Backwards-compatible wrapper that defaults unknown roles to
    [Tool] with a warn log (#8623). *)
val role_of_string : string -> Oas.Types.role

val message_to_json : Oas.Types.message -> Yojson.Safe.t
val message_of_json : Yojson.Safe.t -> Oas.Types.message

(** Project a JSONL entry to its visible-text rendering used by
    history classification. *)
val text_of_history_jsonl_json : Yojson.Safe.t -> string

(** {1 Message repair} *)

(** Insert dangling-tool-use placeholders + drop orphan tool
    results so OAS checkpoint replay never sees a mismatched pair. *)
val repair_broken_tool_call_pairs :
  Oas.Types.message list -> Oas.Types.message list

(** {1 Context (de)serialization} *)

val serialize_context : working_context -> string
val deserialize_context : string -> max_tokens:int -> working_context
val context_to_json : working_context -> Yojson.Safe.t

(** {1 Checkpoint creation / restoration} *)

val create_checkpoint : working_context -> generation:int -> checkpoint

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
  ?source:string -> session_context -> Oas.Types.message -> unit

(** {1 Re-exports from Inference_utils} *)

val timed : (unit -> 'a) -> 'a * float
val zero_usage : Oas.Types.usage
val usage_of_response :
  ?prior:Oas.Types.usage -> Oas.Types.run_result -> Oas.Types.usage
val total_tokens : Oas.Types.usage -> int

(** {1 Checkpoint store delegation} *)

val save_session_checkpoint : session_context -> checkpoint -> unit

(** Save the current working context as a generation-tagged OAS
    checkpoint (truncated, sanitized, repaired). *)
val save_oas_checkpoint :
  max_checkpoint_messages:int ->
  session:session_context ->
  agent_name:string ->
  model:string ->
  ctx:working_context ->
  generation:int ->
  (Oas.Checkpoint.t, string) result

(** Wrap [create_checkpoint] + [save_session_checkpoint] for the
    legacy on-disk checkpoint store. *)
val save_checkpoint :
  session_context -> working_context -> generation:int -> unit

(** {1 OAS checkpoint inspection} *)

val checkpoint_generation : Oas.Checkpoint.t -> fallback:int -> int
val checkpoint_max_tokens : Oas.Checkpoint.t -> fallback:int -> int

(** Pick the keeper's preferred model for checkpointing —
    canonical cascade name first, then a fallback list of
    provider-default labels. *)
val checkpoint_model_of_meta : Keeper_types.keeper_meta -> string

(** Project an OAS checkpoint to a working_context. Optionally
    repair orphan tool results and cap the message tail. *)
val context_of_oas_checkpoint :
  ?repair_orphans:bool ->
  max_checkpoint_messages:int ->
  Oas.Checkpoint.t ->
  primary_model_max_tokens:int ->
  working_context

(** Load the latest OAS / legacy checkpoint for a given
    [trace_id]. Returns the session plus the recovered
    working_context (or [None] when nothing was found). *)
val load_context_from_checkpoint :
  max_checkpoint_messages:int ->
  trace_id:string ->
  primary_model_max_tokens:int ->
  base_dir:string ->
  session_context * working_context option

(** {1 Checkpoint patching} *)

(** Patch the last assistant message in [cp] with a unified
    [session_id] + replay-snapshot metadata + visible response
    text (state blocks stripped). *)
val patch_checkpoint_last_assistant :
  ?snapshot:Keeper_memory_policy.keeper_state_snapshot ->
  Oas.Checkpoint.t ->
  session_id:string ->
  response_text:string ->
  Oas.Checkpoint.t

(** {1 Diagnostics} *)

val log_keeper_exn : label:string -> exn -> unit
