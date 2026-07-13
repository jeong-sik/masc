(** Keeper_tool_call_log — Full I/O logging for keeper tool calls.

    Persists complete tool call records to [.masc/tool_calls/YYYY-MM/DD.jsonl].
    Used by dashboard tool-call inspector for debugging.

    @since 2.249.0 *)

val set_truncation_info :
  keeper_name:string ->
  original_bytes:int ->
  ?truncated_to:int ->
  unit ->
  unit
(** [set_truncation_info ~keeper_name ~original_bytes ?truncated_to ()]
    records pre-truncation output size for the given keeper. Called by
    the tool handler wrapper before returning the (possibly truncated)
    result to OAS. Per-keeper isolation prevents cross-keeper corruption
    under concurrent tool execution. *)

val consume_truncation_info :
  keeper_name:string ->
  unit ->
  int * int option
(** [consume_truncation_info ~keeper_name ()] returns
    [(original_bytes, truncated_to)] for the given keeper and clears
    the pending state. Returns [(0, None)] when no truncation info
    was set (e.g. OAS-internal tool call that bypassed the wrapper). *)

type turn_ctx_cell = Keeper_tool_call_log_context.cell
(** Per-run turn-context carrier (RFC-0225 §3.3). Created once per
    [run_turn] invocation and threaded to every context reader of the
    same run, so concurrent runs of one keeper cannot overwrite each
    other's attribution. *)

val create_turn_ctx_cell : unit -> turn_ctx_cell

val set_turn_context :
  cell:turn_ctx_cell ->
  ?agent_name:string ->
  ?lane:string ->
  ?tool_choice:string ->
  ?thinking_enabled:bool ->
  ?thinking_budget:int ->
  ?prompt_fingerprint:string ->
  ?trace_id:string ->
  ?session_id:string ->
  ?generation:int ->
  ?turn:int ->
  ?keeper_turn_id:int ->
  ?task_id:string ->
  ?goal_ids:string list ->
  ?sandbox_profile:string ->
  ?sandbox_root:string ->
  ?allowed_paths:string list ->
  ?network_mode:string ->
  ?runtime_profile:string ->
  unit ->
  unit
(** [set_turn_context ~cell ...] stores the current effective turn policy
    for subsequent tool-call logs emitted during this run. *)

val get_turn_context :
  cell:turn_ctx_cell ->
  unit ->string option * string option * bool option * int option * string option * string option * string option * int option * int option * string option * string list option * string option * string option
(** Returns [(lane, tool_choice, thinking_enabled, thinking_budget, trace_id,
    prompt_fingerprint, session_id, turn, keeper_turn_id, task_id, goal_ids,
    sandbox_profile, network_mode)] for
    the run, or [None] values when no turn context has
    been recorded. *)

val runtime_observability_contract_json_for_call :
  keeper_name:string ->
  cell:turn_ctx_cell ->
  unit ->
  Yojson.Safe.t
(** [runtime_observability_contract_json_for_call ~keeper_name ~cell ()]
    returns the observability projection from the run's turn context. *)

val action_radius_json_for_call :
  cell:turn_ctx_cell ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  success:bool ->
  duration_ms:float ->
  ?error:string ->
  unit ->
  Yojson.Safe.t
(** [action_radius_json_for_call ...] derives the canonical action radius
    from a keeper tool call and its current sandbox context. *)

val route_evidence_json_of_tool_io :
  tool_name:string ->
  input:Yojson.Safe.t ->
  output_text:string ->
  Yojson.Safe.t option
(** [route_evidence_json_of_tool_io] extracts first-class route proof from a
    keeper tool call. Descriptor-backed calls always include descriptor route
    fields such as [descriptor_id], [public_name], [canonical_name], [executor],
    [backend], [sandbox], evaluation-only [eval_tags], and policy labels.
    Runtime route/status fields such as [via], [sandbox_profile],
    [network_mode], [status], and redacted command/cwd/path are added when
    present. *)

val init : ?cluster_name:string -> base_path:string -> unit -> unit
(** [init ?cluster_name ~base_path ()] creates the cluster-aware Dated_jsonl
    store. Call once at startup. [MASC_TOOL_CALL_LOG_RETENTION_DAYS] controls
    opportunistic retention; default is 30 days, and values <= 0 disable
    pruning. *)

val start_flush_fiber : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> unit
(** [start_flush_fiber ~sw ~clock] enables bounded asynchronous appends and
    starts a background drain fiber. Callers that only invoke [init] keep the
    legacy synchronous append behavior, which is useful for CLI and tests. *)

val flush_now : unit -> unit
(** Drain queued asynchronous appends immediately. Intended for shutdown and
    focused tests. *)

val store_dir : unit -> string option
(** [store_dir ()] returns the initialized durable store directory, if any. *)

val current_log_path : unit -> string option
(** [current_log_path ()] returns today's JSONL file path for the initialized
    durable store, if any. The file may not exist yet when no tool call has
    been appended today. *)

val configured_masc_root : unit -> string option
(** [configured_masc_root ()] returns the cluster-aware MASC root passed to
    [init], even if the store failed to open. Runtime sidecars use this to
    keep their durable projections in the same cluster namespace. *)

val log_call :
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  output_text:string ->
  success:bool ->
  duration_ms:float ->
  ?model:string ->
  ?agent_name:string ->
  ?lane:string ->
  ?tool_choice:string ->
  ?thinking_enabled:bool ->
  ?thinking_budget:int ->
  ?prompt_fingerprint:string ->
  ?execution_id:Ids.Execution_id.t ->
  ?tool_use_id:string ->
  ?trace_id:string ->
  ?session_id:string ->
  ?generation:int ->
  ?turn:int ->
  ?keeper_turn_id:int ->
  ?task_id:string ->
  ?goal_ids:string list ->
  ?sandbox_profile:string ->
  ?sandbox_root:string ->
  ?allowed_paths:string list ->
  ?network_mode:string ->
  ?runtime_profile:string ->
  ?result_bytes:int ->
  ?truncated_to:int ->
  unit ->
  unit
(** [log_call ...] persists a single tool call record with full I/O.
    [execution_id] is the RFC-0233 canonical join key minted once at the
    dispatch boundary; the trajectory row for the same execution carries
    the identical value. [tool_use_id] is the provider call id for the
    same execution (when the dispatch lane has one) — the key that the
    oas:tool_called/oas:tool_completed event rows also carry.
    Output is truncated to 4000 bytes. [model] is a compatibility input only;
    non-empty values are redacted to the neutral runtime lane. [runtime_profile]
    is persisted separately as the operator-facing runtime selector. Turn-policy fields ([lane], [tool_choice],
    [thinking_enabled], [thinking_budget]) capture the effective tool
    selection context. [result_bytes] is the original output size before
    any truncation. [truncated_to] is present when Tool_output_validation
    truncated the output. Best-effort (failures logged). *)

val read_recent :
  ?keeper_name:string ->
  ?n:int ->
  unit ->
  Yojson.Safe.t list
(** [read_recent ?keeper_name ?n ()] returns the [n] most recent entries,
    optionally filtered by keeper name. Default [n=100]. *)

val read_window :
  ?keeper_name:string ->
  window_hours:float ->
  unit ->
  Yojson.Safe.t list
(** [read_window ?keeper_name ~window_hours ()] returns entries within the
    trailing [window_hours]. Non-positive windows return [[]]. *)

val read_latest :
  ?keeper_name:string ->
  unit ->
  Yojson.Safe.t option
(** [read_latest ?keeper_name ()] returns the newest matching entry, if any.
    Uses a small raw-line scan so hot-path callers can avoid materializing
    a larger recent-entry window when they only need the latest tool. *)

val reset_for_testing : unit -> unit
(** Resets the in-memory store reference. For unit tests only. *)

val queued_count_for_testing : unit -> int
(** Number of queued asynchronous append records. For unit tests only. *)

val dropped_count_for_testing : unit -> int
(** Number of records dropped because the asynchronous append queue was full.
    For unit tests only. *)
