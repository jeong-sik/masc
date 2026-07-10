(** Keeper working-context primitives — token counting, message
    history, OAS checkpoint conversion, JSONL persistence.

    Final selective-exposure .mli of the keeper subsystem (PR#3
    series): the largest module in lib/keeper/ at 1401 lines.
    Public API surfaces 47 external callers + closely related
    types; internal sanitizers, JSONL classifiers, and message
    repair helpers stay private. *)

type working_context = Keeper_types.working_context
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
    and token budget.

    [~eio:true] selects the OAS context backend required when the context can
    be touched by Eio fibers. Use [~eio:false] only for synchronous tests or
    serialization fixtures. *)
val create : eio:bool -> system_prompt:string -> max_tokens:int -> working_context

val set_system_prompt :
  working_context -> system_prompt:string -> working_context

val append : working_context -> Agent_sdk.Types.message -> working_context
val append_many : working_context -> Agent_sdk.Types.message list -> working_context

(** Push the working-context's derived counters into the OAS
    [Context.t] (Session scope). *)
val sync_oas_context : working_context -> working_context

(** {1 Working-context projections} *)

val checkpoint_of_context : working_context -> Agent_sdk.Checkpoint.t
val resume_checkpoint_of_context :
  max_checkpoint_messages:int -> working_context -> Agent_sdk.Checkpoint.t
(** Project [working_context] to the checkpoint passed to OAS resume,
    applying the same message count, old-tool-result, per-block, and
    total-content caps used by {!save_oas_checkpoint}. *)

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

(** {1 Message repair} *)

(** Drop dangling tool-use and orphan tool-result blocks so OAS checkpoint
    replay never sees a mismatched pair.  The repair is intentionally
    metadata-only: it must not fabricate visible text that can leak to the
    model or dashboard. *)
val repair_broken_tool_call_pairs :
  Agent_sdk.Types.message list -> Agent_sdk.Types.message list

type tool_pair_repair_stats =
  { dropped_tool_uses : int
  ; dropped_tool_results : int
  ; dropped_tool_use_samples : (string * string) list
  ; dropped_tool_result_ids : string list
  }

val tool_pair_repair_stats_changed : tool_pair_repair_stats -> bool
val pair_repair_diagnostic_max_bytes : int
val bound_pair_repair_diagnostic_string : string -> string

val pair_repair_metadata_key : string
(** Message metadata key carrying bounded provenance for tool-pair repair
    drops. Repaired messages also carry [was_repaired=true]. *)

(** Same repair as {!repair_broken_tool_call_pairs}, plus counters for
    ToolUse/ToolResult blocks dropped from visible content. This keeps the
    repair path observable without changing the legacy return type. *)
val repair_broken_tool_call_pairs_with_stats :
  Agent_sdk.Types.message list -> Agent_sdk.Types.message list * tool_pair_repair_stats

(** {1 Context (de)serialization} *)

val serialize_context : working_context -> string
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

(** Save the current working context as a generation-tagged OAS
    checkpoint (truncated, sanitized, repaired). *)
val save_oas_checkpoint :
  max_checkpoint_messages:int ->
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

val repair_orphan_tool_result_messages_with_stats :
  Agent_sdk.Types.message list -> Agent_sdk.Types.message list * tool_pair_repair_stats

type checkpoint_sanitize_stats = {
  dropped_messages : int;
  dropped_blocks : int;
  dropped_chars : int;
  truncated_blocks : int;
  truncated_chars : int;
  tool_pair_repair : tool_pair_repair_stats;
}

(** Apply [sanitize_checkpoint_messages] (cap blocks / drop oversize
    payloads) and, when [repair_orphans] is [true] (default), also
    drop orphan tool_use/tool_result pairs so the resulting checkpoint
    is safe to persist. Returns the cleaned checkpoint plus aggregated
    stats, including bounded pair-repair diagnostics so dropped
    structural blocks are observable without becoming visible text. *)
val sanitize_oas_checkpoint :
  ?repair_orphans:bool ->
  Agent_sdk.Checkpoint.t ->
  Agent_sdk.Checkpoint.t * checkpoint_sanitize_stats

val checkpoint_sanitize_changed : checkpoint_sanitize_stats -> bool
(** [true] iff any of the counters in [stats] is non-zero. *)

val default_max_checkpoint_tool_result_chars : int
(** Per-tool-result text cap (in chars) applied when projecting
    Anthropic [tool_result] blocks into a checkpoint. Beyond this
    threshold the payload collapses to a stub so a single
    orphan-repair pass cannot inflate one block to multi-MB. *)

val default_max_checkpoint_content_chars_total : int
(** Total persisted Text/tool_result content budget across the retained
    checkpoint message list. The newest messages are kept first; older
    messages are truncated or dropped once this budget is exhausted. *)

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
(** Marker suffix appended to a Text or tool_result block when the
    sanitizer truncates it (newline followed by the [capped] marker).
    Tests assert against this literal so the marker is part of the
    public contract. *)

(** Project an OAS checkpoint to a working_context. Optionally
    repair orphan tool results and cap the message tail. *)
val context_of_oas_checkpoint :
  ?repair_orphans:bool ->
  max_checkpoint_messages:int ->
  Agent_sdk.Checkpoint.t ->
  primary_model_max_tokens:int ->
  working_context

(** Load the canonical OAS checkpoint for a given
    [trace_id]. Returns the session plus the recovered
    working_context (or [None] when nothing was found). *)
val load_context_from_checkpoint :
  max_checkpoint_messages:int ->
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
