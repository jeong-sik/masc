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

val set_turn_context :
  keeper_name:string ->
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
  ?approval_mode:string ->
  ?tool_surface_class:string ->
  ?visible_tool_count:int ->
  ?required_tools:string list ->
  ?missing_required_tools:string list ->
  ?cascade_profile:string ->
  unit ->
  unit
(** [set_turn_context ...] stores the current effective turn policy for
    subsequent tool-call logs emitted by the keeper during this turn. *)

val get_turn_context :
  keeper_name:string ->
  unit ->string option * string option * bool option * int option * string option * string option * string option * int option * int option * string option * string list option * string option * string option * string option
(** Returns [(lane, tool_choice, thinking_enabled, thinking_budget, trace_id,
    prompt_fingerprint, session_id, turn, keeper_turn_id, task_id, goal_ids,
    sandbox_profile, network_mode, approval_mode)] for
    the keeper, or [None] values when no turn context has
    been recorded. *)

val runtime_contract_json_for_call :
  keeper_name:string ->
  ?model:string ->
  unit ->
  Yojson.Safe.t
(** [runtime_contract_json_for_call ~keeper_name ?model ()] returns the
    canonical keeper runtime contract from the current turn context. *)

val action_radius_json_for_call :
  keeper_name:string ->
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
(** [route_evidence_json_of_tool_io] extracts first-class route proof from
    keeper git/gh tool I/O. The evidence includes redacted command/cwd/path
    from the input plus route/status fields such as [via], [sandbox_profile],
    [git_creds_enabled], [network_mode], [status], and PR URL when present. *)

val init : ?cluster_name:string -> base_path:string -> unit -> unit
(** [init ?cluster_name ~base_path ()] creates the cluster-aware Dated_jsonl
    store. Call once at startup. *)

val store_dir : unit -> string option
(** [store_dir ()] returns the initialized durable store directory, if any. *)

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
  ?approval_mode:string ->
  ?tool_surface_class:string ->
  ?visible_tool_count:int ->
  ?required_tools:string list ->
  ?missing_required_tools:string list ->
  ?cascade_profile:string ->
  ?result_bytes:int ->
  ?truncated_to:int ->
  unit ->
  unit
(** [log_call ...] persists a single tool call record with full I/O.
    Output is truncated to 4000 bytes. [model] records which LLM generated
    the tool call. Turn-policy fields ([lane], [tool_choice],
    [thinking_enabled], [thinking_budget]) capture the effective tool
    selection context. [result_bytes] is the original output size before
    any truncation. [truncated_to] is present when Tool_output_validation
    truncated the output. Best-effort (failures logged). *)

val remember_handler_logged :
  keeper_name:string ->
  tool_name:string ->
  output_text:string ->
  success:bool ->
  unit ->
  unit
(** [remember_handler_logged ...] records that the keeper tool handler has
    already persisted the full I/O for this just-completed tool execution.
    Agent SDK post-tool hooks consume this marker to avoid duplicate rows
    when a provider emits both handler-side and hook-side signals. *)

val consume_handler_logged :
  keeper_name:string ->
  tool_name:string ->
  output_text:string ->
  success:bool ->
  unit ->
  bool
(** [consume_handler_logged ...] returns [true] once when a recent
    handler-side log marker matches the post-tool hook event. *)

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
