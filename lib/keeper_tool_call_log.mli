(** Keeper_tool_call_log — Full I/O logging for keeper tool calls.

    Persists complete tool call records to [.masc/tool_calls/YYYY-MM/DD.jsonl].
    Used by dashboard tool-call inspector for debugging.

    @since 2.249.0 *)

val max_output_len : int
(** Bytes of a record's serialized output that reach disk; the rest is cut with
    a [...(truncated)] suffix. Exposed because payload builders order their
    fields against it — an unbounded field placed before a diagnostic one takes
    the diagnostic away with it (see
    [Keeper_tool_composition_surface.failure_payload]). *)

val set_truncation_info :
  invocation:Agent_core.Tool_contract.Invocation.t ->
  original_bytes:int ->
  ?truncated_to:int ->
  unit ->
  unit
(** [set_truncation_info ~invocation ~original_bytes ?truncated_to ()]
    records pre-truncation output size for the exact invocation. Called by
    the tool handler wrapper before returning the (possibly truncated)
    result to AGENT_CORE. Physical invocation identity preserves isolation even
    when a provider emits blank or repeated tool-use ids. Weak ownership lets a
    cancelled invocation release its pending observation. *)

val consume_truncation_info :
  invocation:Agent_core.Tool_contract.Invocation.t ->
  unit ->
  int * int option
(** [consume_truncation_info ~invocation ()] returns
    [(original_bytes, truncated_to)] for the exact invocation and clears
    the pending state. Returns [(0, None)] when no truncation info
    was set (e.g. AGENT_CORE-internal tool call that bypassed the wrapper). *)

val set_disposition :
  invocation:Agent_core.Tool_contract.Invocation.t ->
  disposition:(unit, unit, Tool_result.tool_failure_class) Tool_result.disposition ->
  unit
(** [set_disposition ~invocation ~disposition] records the typed outcome for
    the exact invocation, alongside {!set_truncation_info} and for the same
    reason: the boundary between the masc dispatch and the hook that writes
    the row narrows the value, and the hook cannot get it back. AGENT_CORE
    hands the hook a [tool_result] that cannot represent [Deferred] and whose
    error class is a different taxonomy from [tool_failure_class]. *)

val consume_disposition :
  invocation:Agent_core.Tool_contract.Invocation.t ->
  unit ->
  (unit, unit, Tool_result.tool_failure_class) Tool_result.disposition option
(** [consume_disposition ~invocation ()] returns the typed outcome for the
    exact invocation and clears it. [None] for a call that did not come
    through the masc dispatch boundary. *)

val set_file_change_evidence :
  invocation:Agent_core.Tool_contract.Invocation.t ->
  evidence:Keeper_file_change_evidence.t ->
  unit
(** Preserve producer-owned file line evidence for the exact physical
    invocation until the post-tool hook constructs its tool-call row. *)

val consume_file_change_evidence :
  invocation:Agent_core.Tool_contract.Invocation.t ->
  unit ->
  Keeper_file_change_evidence.t option
(** Return and clear file change evidence for the exact invocation. *)

val peek_file_change_evidence :
  invocation:Agent_core.Tool_contract.Invocation.t ->
  unit ->
  Keeper_file_change_evidence.t option
(** Return file change evidence without clearing it. The post-tool hook uses
    this to build a synchronous row and consumes it only after commit. *)

type turn_ctx_cell = Keeper_tool_call_log_context.cell
(** Per-run turn-context carrier (RFC-0225 §3.3). Created once per
    [run_turn] invocation and threaded to every context reader of the
    same run, so concurrent runs of one keeper cannot overwrite each
    other's attribution. *)

val create_turn_ctx_cell : unit -> turn_ctx_cell

val set_turn_context :
  cell:turn_ctx_cell ->
  ?agent_name:string ->
  ?turn_kind:Turn_record.turn_kind ->
  ?lane:string ->
  ?tool_choice:string ->
  ?thinking_enabled:bool ->
  ?thinking_budget:int ->
  ?prompt_fingerprint:string ->
  ?trace_id:string ->
  ?session_id:string ->
  ?turn:int ->
  ?keeper_turn_id:int ->
  ?task_id:string ->
  ?sandbox_profile:string ->
  ?sandbox_root:string ->
  ?sandbox_roots:string list ->
  ?network_mode:string ->
  ?runtime_profile:string ->
  unit ->
  unit
(** [set_turn_context ~cell ...] stores the current effective turn policy
    for subsequent tool-call logs emitted during this run. *)

val get_turn_context :
  cell:turn_ctx_cell ->
  unit ->string option * string option * bool option * int option * string option * string option * string option * int option * int option * string option * string option * string option
(** Returns [(lane, tool_choice, thinking_enabled, thinking_budget, trace_id,
    prompt_fingerprint, session_id, turn, keeper_turn_id, task_id,
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
    present. Composition surface tools are not descriptor-backed; their
    RFC-0386 [tool_kind] is picked up from the tool's own result payload when
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

val committed_revision : unit -> int
(** Monotonic in-process revision advanced exactly after each successful
    durable tool-call append. Readers use it to invalidate derived caches
    without making the persistence owner depend on a dashboard module. *)

type record_kind =
  | Tool_call
  | Composition_run

val log_call :
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  output_text:string ->
  success:bool ->
  duration_ms:float ->
  ?record_kind:record_kind ->
  ?model:string ->
  ?agent_name:string ->
  ?turn_kind:Turn_record.turn_kind ->
  ?lane:string ->
  ?tool_choice:string ->
  ?thinking_enabled:bool ->
  ?thinking_budget:int ->
  ?prompt_fingerprint:string ->
  ?execution_id:Ids.Execution_id.t ->
  ?tool_use_id:string ->
  ?planned_index:int ->
  ?batch_index:int ->
  ?batch_size:int ->
  ?execution_mode:Agent_core.Tool_contract.execution_mode ->
  ?typed_result:Tool_result.result ->
  ?disposition:
    (unit, unit, Tool_result.tool_failure_class) Tool_result.disposition ->
  ?file_change_evidence:Keeper_file_change_evidence.t ->
  ?composition_tool:string ->
  ?skill_reference:Skill_reference.t ->
  ?composition_run_id:string ->
  ?composition_node_id:string ->
  ?composition_execution:Keeper_tool_composition_catalog.execution_mode ->
  ?composition_tool_kind:Keeper_tool_descriptor.tool_kind ->
  ?parent_tool_use_id:string ->
  ?trace_id:string ->
  ?session_id:string ->
  ?turn:int ->
  ?keeper_turn_id:int ->
  ?task_id:string ->
  ?sandbox_profile:string ->
  ?sandbox_root:string ->
  ?sandbox_roots:string list ->
  ?network_mode:string ->
  ?runtime_profile:string ->
  ?result_bytes:int ->
  ?truncated_to:int ->
  ?on_committed:(unit -> unit) ->
  unit ->
  unit
(** [log_call ...] persists a single tool call record with full I/O.
    [record_kind] defaults to [Tool_call]; [Composition_run] is the explicit
    terminal aggregate for a composition and must not be interpreted as a
    second physical invocation. [skill_reference], when present, is the exact
    published Skill revision that produced the run; clients must not infer it
    from the mutable composition tool name.
    [execution_id] is the RFC-0233 canonical join key minted once at the
    dispatch boundary; the trajectory row for the same execution carries
    the identical value. [tool_use_id] is the provider call id for the
    same execution (when the dispatch lane has one) — the key that the
    agent_core:tool_called/agent_core:tool_completed event rows also carry. Blank and
    repeated provider ids remain meaningful when scoped by [turn] and
    [planned_index], so they are persisted unchanged. [batch_index],
    [batch_size], and [execution_mode] preserve Agent Core's actual schedule
    rather than inferring concurrency from timing.
    [typed_result] serializes the producer-owned disposition when it is
    available. Any canonical normalized artifact references in its typed data
    are also persisted as actual JSON under [artifact_refs], keeping the
    content-addressed blobs visible to offline maintenance without parsing a
    JSON-bearing model-output string. Those GC roots deliberately carry an
    empty preview; model/UI preview projection remains owned by [output]. The
    composition fields are an explicit observation envelope supplied by the
    typed plan executor; readers must not reconstruct them from [tool_use_id]
    or tool-name strings. [file_change_evidence] is producer-owned typed data,
    persisted independently of the truncated opaque [output] preview.
    [on_committed], when supplied, forces this row through the synchronous
    append boundary and runs only after that append succeeds. It is intended
    for exact completion notifications whose readers must not race the
    asynchronous log queue. [turn_kind] names which turn made the call —
    a submitted operation's turn or the keeper's own autonomous cycle —
    so a reader can join calls to a submission instead of inferring the
    boundary from timestamps that a concurrent autonomous turn overlaps.
    Output is truncated to 4000 bytes. [model] is a compatibility input only;
    non-empty values are redacted to the neutral runtime lane. [runtime_profile]
    is persisted separately as the operator-facing runtime selector. Turn-policy fields ([lane], [tool_choice],
    [thinking_enabled], [thinking_budget]) capture the effective tool
    selection context. [result_bytes] is the original output size before
    any observation-only log preview truncation. [truncated_to] records the
    retained preview size when one exists; it never describes mutation of the
    Tool result delivered to the Keeper. Best-effort (failures logged). *)

val read_recent :
  ?keeper_name:string ->
  ?n:int ->
  unit ->
  Yojson.Safe.t list
(** [read_recent ?keeper_name ?n ()] returns the [n] most recent entries,
    optionally filtered by keeper name. Default [n=100]. Reads the store tail
    only far enough to answer: [n] rows unfiltered, [n *
    {!read_over_scan_factor}] when filtering by keeper. *)

val read_over_scan_factor : int
(** Scan multiplier [read_recent] applies before its keeper filter: to end up
    with [n] rows from one keeper it reads [n * read_over_scan_factor] fleet
    rows. Callers sharing one fleet read ({!read_recent_rows}) size their
    window with this to reproduce a per-keeper [read_recent]'s coverage.

    It applies only when [keeper_name] is given. Without one the filter keeps
    every row, so reading past [n] would parse rows that {!read_recent} then
    discards — on a store averaging 6.8 KB per row that was 165 MB read for an
    answer 33 MB contains. *)

val read_recent_rows : n:int -> unit -> Yojson.Safe.t list
(** [read_recent_rows ~n ()] returns the [n] most recent fleet-wide rows
    with no keeper filter. One shared read serves every per-keeper
    {!filter_rows_for_keeper} derivation, instead of each keeper
    re-parsing the store. *)

val filter_rows_for_keeper :
  keeper_name:string -> n:int -> Yojson.Safe.t list -> Yojson.Safe.t list
(** [filter_rows_for_keeper ~keeper_name ~n rows] is [read_recent]'s
    keeper filter applied to an already-read row window: rows whose
    ["keeper"] field equals [keeper_name], order preserved, truncated to
    the last [n]. *)

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

val pending_truncation_count_for_testing : unit -> int
(** Number of live invocation-scoped truncation observations. Test only. *)

val pending_file_change_evidence_count_for_testing : unit -> int
(** Number of live invocation-scoped file change observations. Test only. *)

val queued_count_for_testing : unit -> int
(** Number of queued asynchronous append records. For unit tests only. *)
