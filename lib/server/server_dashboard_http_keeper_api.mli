(** Server Dashboard HTTP — keeper-API surface.

    Implements the [/api/v1/keepers/<name>/...] family used by the
    operator dashboard.  Owns the route classifier, request body
    handlers, trajectory merge logic, and checkpoint inventory.  Most
    helpers are exported so the dashboard test suite can exercise the
    classifier and JSON shapes in isolation. *)

module Http = Http_server_eio
(** Alias used internally for the Eio HTTP server module. *)

val tool_calls_fleet_cache_key : masc_root:string -> string
(** Return the bounded fleet-row cache key after invalidating its cached value
    when the durable tool-call revision has advanced. *)

val file_changes_default_window_hours : float
val file_changes_max_window_hours : float
(** Shared read-cost bounds for durable file-change projections. The
    per-Keeper and file-centric routes must state and clamp the same trailing
    window rather than silently scanning different histories. *)

(** {1 Trajectory projection} *)

val handle_keeper_fusion_post :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle [POST /fusion] by starting an out-of-band deliberation owned by the
    keeper in the route, with the prompt, preset and topology supplied by the
    operator. This is the only HTTP surface that can reach the judge-of-judges
    and staged topologies; before it only a keeper deciding to call the tool
    itself could run them. *)

val handle_keeper_operator_note_post :
  Mcp_server.server_state ->
  string ->
  Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle [POST /operator-note] by replacing this keeper's pending note
    (RFC-0366). The note renders on the next turn that assembles and is then
    stamped consumed; oversized text is rejected rather than truncated. *)

val handle_keeper_board_attention_quarantine_recovery_post :
  Mcp_server.server_state ->
  string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  keeper_name:string ->
  raw_partition_id:string ->
  string ->
  unit
(** Acknowledge and requeue one exact Board-attention quarantine. The route is
    wired only behind token-bound [CanAdmin] authorization. *)

(** {1 POST route classifier}

    keeper_post_route_kind ADT + classifier + path helpers live in
    Server_dashboard_http_keeper_api_types (intra-library file split,
    2026-05-16). Re-exported via include below. *)
include module type of Server_dashboard_http_keeper_api_types

(** Trajectory preview helpers (trim_to_opt / truncate_text /
    latest_preview_of_messages)
    moved to Server_dashboard_http_keeper_api_types — re-exported via
    [include module type of] above. *)

(** {1 Chat history paging} *)

val attach_keeper_chat_skill_activations :
  config:Workspace.config -> Yojson.Safe.t -> Yojson.Safe.t
(** Attach the exact-turn Skill activation projection to assistant chat rows.
    A row that reports [keeper_skill] but has no matching retained activation
    receives an explicit missing/unavailable status; no timestamp or row-order
    inference is used. Exposed so the server JSON contract can be tested
    without opening an HTTP listener. *)

val keeper_chat_history_json : Workspace.config -> string -> Yojson.Safe.t
(** Body for [GET /chat/history]: the chat-store tail window plus every
    autonomous turn retention still holds. Every row carries a stable [id] —
    the dashboard history schema silently drops rows without one. *)

val keeper_chat_history_page_json :
  Workspace.config -> string -> before:float option -> Yojson.Safe.t
(** Body for [GET /chat/history/page]: direct-conversation rows older than
    [before], newest window when [before] is [None].

    Autonomous turns are not included. They are bounded by
    {!Masc.Keeper_raw_trace_retention.history_limit} rather than by this window,
    so [GET /chat/history] already carried every one that exists; repeating them
    per page would duplicate rows the caller holds.

    [next_before] is the cursor for the following page — the oldest [ts] among
    the returned rows, or [`Null] for an empty page. A caller must stop on a
    null cursor rather than resend the previous one. *)

(** {1 Checkpoint inventory} *)

val stat_json_of_path : string -> Yojson.Safe.t
(** [stat] result as JSON; [`Null] when the file is missing. *)

val agent_core_checkpoint_summary_json :
  source_kind:string ->
  snapshot_id:string ->
  path:string ->
  is_current:bool ->
  Agent_core.Checkpoint.t ->
  Yojson.Safe.t
(** JSON summary of an AGENT_CORE checkpoint, used by the inventory listing. *)

val keeper_checkpoint_inventory_json :
  Workspace.config -> string -> [ `Not_found | `OK ] * Yojson.Safe.t
(** Inventory JSON for [GET /checkpoints]. *)

val keeper_runtime_trace_json :
  Workspace.config ->
  string ->
  ?trace_id:string ->
  ?turn_id:int ->
  ?limit:int ->
  unit ->
  [ `Not_found | `OK ] * Yojson.Safe.t
(** Runtime manifest + receipt evidence chain for [GET /runtime-trace]. *)

val offline_keeper_composite_json :
  config:Workspace.config ->
  string -> Keeper_meta_contract.keeper_meta -> Yojson.Safe.t
(** Offline/paused composite fallback for keepers missing from the live
    registry. Exposed so dashboard tests can pin the JSON shape. *)

(** {1 Keeper state diagram runtime projection} *)

type state_diagram_runtime_projection =
  { runtime_models : string list
  ; last_provider_result : string option
  ; runtime_models_source : string
  ; last_provider_result_source : string
  ; effective_runtime_reason : string option
  }

val state_diagram_runtime_projection :
  Keeper_meta_contract.keeper_meta option -> state_diagram_runtime_projection
(** Redacted runtime/provider projection for [GET /state-diagram].
    It never exposes concrete AGENT_CORE provider or model identifiers. *)

val state_diagram_runtime_projection_json :
  state_diagram_runtime_projection -> Yojson.Safe.t
(** JSON fields embedded in the [GET /state-diagram] response. *)

val state_diagram_runtime_fsm_mermaid :
  state_diagram_runtime_projection -> string
(** Runtime FSM Mermaid rendered from the redacted projection. *)

val handle_keeper_checkpoints_post :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle admin [POST /checkpoints] history deletion and checkpoint purge. *)

(** {1 Keeper name validation} *)

val is_valid_keeper_name : String.t -> bool
(** [true] when [name] passes the shared keeper-name character class. *)

val extract_keeper_name_for_post : string -> string -> string
(** [extract_keeper_name_for_post path suffix]: the POST dispatcher's
    spelling of the suffix extractor, and the same function. The argument
    order is [path] then [suffix]; this signature used to document it the
    other way round. *)

(** {1 Execution surface refresh} *)

val refresh_keeper_execution_surfaces :
  config:Workspace_utils.config ->
  name:String.t ->
  Keeper_lifecycle_events.lifecycle_event ->
  unit
(** Re-read the keeper meta for [name] and update derived caches. *)

val invalidate_keeper_execution_surfaces :
  config:Workspace_utils.config -> unit -> unit
(** Drop every cached keeper execution surface; called on server-wide
    reconfiguration. *)

(** {1 Action handlers} *)

val handle_keeper_config_post :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  Mcp_server.server_state ->
  string -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle [POST /config] (TOML edits). *)

val handle_keeper_secrets_post :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle [POST /secrets] (redacted env-secret projection edits). *)

val handle_keeper_github_login_post :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Stream an isolated GitHub CLI login for the selected keeper. *)

val handle_keeper_oauth_login_post :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle [POST /oauth-login]: begin attaching this keeper to the declared
    provider named in the body, and answer with the URL to open. *)

val handle_keeper_identity_refresh_post :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle [POST /identity-refresh]: ask an attached provider again what
    tools it has, and write the answer down. *)

val handle_keeper_identity_switch_post :
  Mcp_server.server_state ->
  actor:string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  string ->
  unit
(** Handle [POST /identity-switch]: turn one attached service on or off for
    this keeper without touching the consent. Body: [{provider, enabled}]. *)

val handle_keeper_lifecycle_post :
  ?body_str:string ->
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  tool_name:string ->
  action:String.t ->
  Mcp_server.server_state ->
  string -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Generic handler for boot / shutdown / reset / clear posts. Boot does not
    resume an ordinary paused owner; callers must commit [Resume_owner] through
    the directive endpoint. *)

val handle_keeper_directive_post :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  Mcp_server.server_state ->
  string -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle [POST /directive] (operator directive injection). A resume body
    must carry a stable [operator_operation_id], and is
    committed through the typed paused-work disposition transaction. *)

val handle_keeper_paused_work_post :
  Mcp_server.server_state ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  string ->
  unit
(** Handle authenticated [POST /paused-work] for exact Resume, Transfer,
    Cancel, or source-terminal disposition. *)

val handle_keeper_bulk_directive_post :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  Mcp_server.server_state ->
  string -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle [POST /api/v1/keepers_bulk/directive]. Pause and wakeup use
    [{"names": [...]}]. Resume uses exact per-owner
    [{"targets": [{"name", "operator_operation_id"}, ...]}]
    fences and commits each target through the typed paused-work disposition
    transaction. Cache invalidation runs once for the whole batch. *)

val handle_keeper_get_subroutes :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Dispatch [GET /api/v1/keepers/<name>/<sub>] sub-routes
    (status / tools / checkpoints listing / etc.). *)

(** {1 Memory-OS dashboard JSON} *)

val memory_os_fact_json :
  current:bool -> Keeper_memory_os_types.fact -> Yojson.Safe.t
(** One current fact's read-only dashboard projection. [current] is derived
    from snapshot membership; no retention, score, or legacy kind field is
    serialized. *)
