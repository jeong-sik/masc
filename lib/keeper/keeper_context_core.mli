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
val msg_tokens : Agent_sdk.Types.message -> int

(** Total tokens across [system_prompt] + every message. *)
val count_tokens : string -> Agent_sdk.Types.message list -> int

val token_count : working_context -> int
val message_count : working_context -> int
val context_ratio : working_context -> float
val max_tokens_of_context : working_context -> int

(** Replace the working-context's [max_tokens]; mirrors the value
    into [checkpoint.max_total_tokens]. *)
val with_max_tokens : working_context -> int -> working_context

(** Re-export of [Agent_sdk.Types.text_of_message]. *)
val text_of_message : Agent_sdk.Types.message -> string

(** {1 Working-context construction & mutation} *)

(** Construct a fresh working context with the given system prompt
    and token budget. *)
val create : system_prompt:string -> max_tokens:int -> working_context

val set_system_prompt :
  working_context -> system_prompt:string -> working_context

val append : working_context -> Agent_sdk.Types.message -> working_context
val append_many : working_context -> Agent_sdk.Types.message list -> working_context

(** Push the working-context's derived counters into the OAS
    [Context.t] (Session scope). *)
val sync_oas_context : working_context -> working_context

(** {1 Working-context projections} *)

val checkpoint_of_context : working_context -> Agent_sdk.Checkpoint.t
val oas_context_of_context : working_context -> Agent_sdk.Context.t
val system_prompt_of_context : working_context -> string
val messages_of_context : working_context -> Agent_sdk.Types.message list

(** {1 Role / message JSON} *)

val role_to_string : Agent_sdk.Types.role -> string

(** [Some] only for the four wire-format names; callers must
    handle [None] explicitly (#8623). *)
val role_of_string_opt : string -> Agent_sdk.Types.role option

(** Backwards-compatible wrapper that defaults unknown roles to
    [Tool] with a warn log (#8623). *)
val role_of_string : string -> Agent_sdk.Types.role

val message_to_json : Agent_sdk.Types.message -> Yojson.Safe.t
val message_of_json : Yojson.Safe.t -> Agent_sdk.Types.message

(** Project a JSONL entry to its visible-text rendering used by
    history classification. *)
val text_of_history_jsonl_json : Yojson.Safe.t -> string

(** {1 Message repair} *)

(** Insert dangling-tool-use placeholders + drop orphan tool
    results so OAS checkpoint replay never sees a mismatched pair. *)
val repair_broken_tool_call_pairs :
  Agent_sdk.Types.message list -> Agent_sdk.Types.message list

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
  ?source:string -> session_context -> Agent_sdk.Types.message -> unit

(** {1 Re-exports from Inference_utils} *)

val timed : (unit -> 'a) -> 'a * int
val zero_usage : Agent_sdk.Types.api_usage
val usage_of_response :
  Oas_response.api_response -> Agent_sdk.Types.api_usage
val total_tokens : Agent_sdk.Types.api_usage -> int

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
  (Agent_sdk.Checkpoint.t, string) result

(** Wrap [create_checkpoint] + [save_session_checkpoint] for the
    legacy on-disk checkpoint store; returns the persisted
    checkpoint so callers can use it without re-reading from disk. *)
val save_checkpoint :
  session_context -> working_context -> generation:int -> checkpoint

(** {1 OAS checkpoint inspection} *)

val checkpoint_generation : Agent_sdk.Checkpoint.t -> fallback:int -> int
val checkpoint_max_tokens : Agent_sdk.Checkpoint.t -> fallback:int -> int

(** Drop orphan [tool_result] blocks (those without a matching
    preceding [tool_use]) so a checkpoint payload satisfies the
    Anthropic API invariant that every tool_result references a known
    tool_use. Public so [Keeper_rollover] / [Keeper_post_turn] can
    reuse it before persisting a checkpoint. *)
val repair_orphan_tool_result_messages :
  Agent_sdk.Types.message list -> Agent_sdk.Types.message list

type checkpoint_sanitize_stats = {
  dropped_messages : int;
  dropped_blocks : int;
  dropped_chars : int;
  truncated_blocks : int;
  truncated_chars : int;
}

(** Apply [sanitize_checkpoint_messages] (cap blocks / drop oversize
    payloads) and, when [repair_orphans] is [true] (default), also
    drop orphan tool_use/tool_result pairs so the resulting checkpoint
    is safe to persist. Returns the cleaned checkpoint plus
    aggregated stats. *)
val sanitize_oas_checkpoint :
  ?repair_orphans:bool ->
  Agent_sdk.Checkpoint.t ->
  Agent_sdk.Checkpoint.t * checkpoint_sanitize_stats

val checkpoint_sanitize_changed : checkpoint_sanitize_stats -> bool
(** [true] iff any of the counters in [stats] is non-zero. *)

(** Load the newest legacy checkpoint persisted under
    [session.session_dir]; returns [None] when nothing has been
    persisted yet. *)
val load_latest_checkpoint : session_context -> checkpoint option

(** Recover a [working_context] from the legacy on-disk checkpoint
    shape, capping by [primary_model_max_tokens]. *)
val context_of_legacy_checkpoint :
  checkpoint -> primary_model_max_tokens:int -> working_context

val default_max_checkpoint_tool_result_chars : int
(** Per-tool-result text cap (in chars) applied when projecting
    Anthropic [tool_result] blocks into a checkpoint. Beyond this
    threshold the payload collapses to a stub so a single
    orphan-repair pass cannot inflate one block to multi-MB. *)

val tool_result_text_of_block :
  tool_use_id:string ->
  content:string ->
  json:Yojson.Safe.t option ->
  string
(** Project a [tool_result] block to its on-checkpoint string form,
    applying {!default_max_checkpoint_tool_result_chars}. Exposed so
    [test_keeper_context_core_dedup] can pin the dedup contract
    without re-implementing the projection. *)

val sanitize_checkpoint_message :
  Agent_sdk.Types.message -> Agent_sdk.Types.message option * checkpoint_sanitize_stats
(** Apply the per-message portion of {!sanitize_oas_checkpoint}: cap
    Text and tool_result blocks, drop empties, return the cleaned
    message (or [None] if every block was dropped) plus its stats.
    Exposed so [test_keeper_lifecycle] can pin the sanitization
    contract block-by-block. *)

val checkpoint_text_cap_marker : string
(** Sentinel suffix appended to a Text or tool_result block when the
    sanitizer truncates it (newline followed by the [capped] marker).
    Tests assert against this literal so the marker is part of the
    public contract. *)

(** Pick the keeper's preferred model for checkpointing —
    canonical cascade name first, then a fallback list of
    provider-default labels. *)
val checkpoint_model_of_meta : Keeper_types.keeper_meta -> string

(** Project an OAS checkpoint to a working_context. Optionally
    repair orphan tool results and cap the message tail. *)
val context_of_oas_checkpoint :
  ?repair_orphans:bool ->
  max_checkpoint_messages:int ->
  Agent_sdk.Checkpoint.t ->
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
  Agent_sdk.Checkpoint.t ->
  session_id:string ->
  response_text:string ->
  Agent_sdk.Checkpoint.t

(** {1 Diagnostics} *)

val log_keeper_exn : label:string -> exn -> unit
