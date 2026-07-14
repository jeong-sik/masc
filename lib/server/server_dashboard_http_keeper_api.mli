(** Server Dashboard HTTP — keeper-API surface.

    Implements the [/api/v1/keepers/<name>/...] family used by the
    operator dashboard.  Owns the route classifier, request body
    handlers, trajectory merge logic, and checkpoint inventory.  Most
    helpers are exported so the dashboard test suite can exercise the
    classifier and JSON shapes in isolation. *)

module Http = Http_server_eio
(** Alias used internally for the Eio HTTP server module. *)

(** {1 Route prefix and suffixes} *)

val keeper_api_prefix : string
(** [/api/v1/keepers/] common prefix for every route below. *)

val keeper_suffix_config : string
val keeper_suffix_secrets : string
val keeper_suffix_boot : string
val keeper_suffix_shutdown : string
val keeper_suffix_reset : string
val keeper_suffix_clear : string
val keeper_suffix_checkpoints : string
val keeper_suffix_runtime_trace : string
val keeper_suffix_directive : string

(** {1 Trajectory merge}

    The dashboard merges the on-disk turn trajectory with internal-history
    lines (per-turn snapshots from the keeper subprocess) so the operator
    sees both LLM messages and structural events in one feed. *)

val trajectory_line_ts : Trajectory.trajectory_line -> float
(** Extract the timestamp used as the merge key. *)

val dedupe_thinking_lines :
  Trajectory.trajectory_line list ->
  Trajectory.trajectory_line list
(** Collapse consecutive identical "thinking" lines to one entry. *)

val internal_history_json_to_trajectory_line :
  Yojson.Safe.t -> Trajectory.trajectory_line option
(** Parse a single internal-history JSON entry into a trajectory line;
    [None] for malformed entries. *)

val read_internal_history_lines :
  config:Workspace.config ->
  trace_id:string -> Trajectory.trajectory_line list
(** Read the internal-history file for [trace_id] under [config]. *)

val merge_keeper_trace_lines :
  config:Workspace.config ->
  trace_id:string ->
  Trajectory.trajectory_line list ->
  Trajectory.trajectory_line list
(** Merge [trajectory_lines] with the internal-history file in
    timestamp order, applying [dedupe_thinking_lines]. *)

val handle_keeper_catchup_judge_post :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle [POST /catchup-judge] by recomputing the keeper catch-up digest
    and starting an out-of-band Fusion judge run. *)

val handle_keeper_chat_recovery_post :
  Mcp_server.server_state ->
  string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  keeper_name:string ->
  raw_receipt_id:string ->
  string ->
  unit
(** Resolve exactly one recovery-required chat receipt using the caller's
    revision and lease evidence. The route is wired only behind token-bound
    [CanAdmin] authorization. *)

(** {1 POST route classifier}

    keeper_post_route_kind ADT + classifier + path helpers live in
    Server_dashboard_http_keeper_api_types (intra-library file split,
    2026-05-16). Re-exported via include below. *)
include module type of Server_dashboard_http_keeper_api_types

(** Trajectory preview helpers (trim_to_opt / truncate_text /
    latest_preview_of_messages)
    moved to Server_dashboard_http_keeper_api_types — re-exported via
    [include module type of] above. *)

(** {1 Checkpoint inventory} *)

val stat_json_of_path : string -> Yojson.Safe.t
(** [stat] result as JSON; [`Null] when the file is missing. *)

val oas_checkpoint_summary_json :
  source_kind:string ->
  snapshot_id:string ->
  path:string ->
  is_current:bool ->
  fallback_generation:int ->
  Agent_sdk.Checkpoint.t ->
  Yojson.Safe.t
(** JSON summary of an OAS checkpoint, used by the inventory listing. *)

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
    It never exposes concrete OAS provider or model identifiers. *)

val state_diagram_runtime_projection_json :
  state_diagram_runtime_projection -> Yojson.Safe.t
(** JSON fields embedded in the [GET /state-diagram] response. *)

val state_diagram_runtime_fsm_mermaid :
  state_diagram_runtime_projection -> string
(** Runtime FSM Mermaid rendered from the redacted projection. *)

val handle_keeper_checkpoints_post :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle [POST /checkpoints] (rollback / pin actions). *)

(** {1 Keeper name validation} *)

val is_valid_keeper_name : String.t -> bool
(** [true] when [name] passes the shared keeper-name character class. *)

val extract_keeper_name_for_post : string -> string -> string
(** [extract_keeper_name_for_post suffix path]: variant used by the
    POST dispatcher. *)

(** {1 Execution surface refresh} *)

val refresh_keeper_execution_surfaces :
  config:Workspace_utils.config -> name:String.t -> string -> unit
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

val handle_keeper_lifecycle_post :
  ?body_str:string ->
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  tool_name:string ->
  action:String.t ->
  Mcp_server.server_state ->
  string -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Generic handler for boot / shutdown / reset / clear posts; the
    [action] parameter selects the keeper FSM event. *)

val handle_keeper_directive_post :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  Mcp_server.server_state ->
  string -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle [POST /directive] (operator directive injection). *)

val handle_keeper_bulk_directive_post :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  Mcp_server.server_state ->
  string -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle [POST /api/v1/keepers_bulk/directive]. Body:
    [{"names": [...], "action": "pause"|"resume"|"wakeup"}]. Runs the
    same per-keeper meta read / persist / dispatch path as
    [handle_keeper_directive_post], but issues a single cache invalidate
    for the whole batch. Trades per-keeper observability granularity for
    bulk performance: a fleet-wide resume is 1 round-trip + 1 rebuild
    instead of N + N. *)

val handle_keeper_get_subroutes :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Dispatch [GET /api/v1/keepers/<name>/<sub>] sub-routes
    (status / tools / checkpoints listing / etc.). *)

val keeper_chat_receipt_route : string -> (string * string) option
(** Parse the exact
    [/api/v1/keepers/<name>/chat/receipts/<receipt_id>] read route. *)

(** {1 Memory-OS dashboard JSON} *)

val memory_os_fact_json :
  now:float -> Keeper_memory_os_types.fact -> Yojson.Safe.t
(** RFC-keeper-memory-panel-real-data §4a: one fact's read-only dashboard projection — claim, typed
    category, provenance, the three timestamps, current-ness, and optional
    claim_kind. Serializes only fields present on [fact]; it
    cannot emit the score fields RFC-0247 deleted (they are not on the record).
    Exported so the test suite can assert the JSON shape (and that drift guard)
    in isolation, per the module's "JSON shapes exported for testing" convention. *)

val memory_os_dashboard_json : keeper_id:string -> Yojson.Safe.t
(** RFC-keeper-memory-panel-real-data §4a: the full recall-observability payload
    for one keeper — episode/fact counts plus the per-row [items] arrays read
    from the keeper's on-disk stores. Exported so the test suite can assert the
    facts [items] are wired (one row per persisted fact); [memory_os_fact_json],
    being a pure per-fact projection, cannot guard that wiring on its own. *)

val compaction_snapshots_json :
  config:Workspace.config -> keeper_id:string -> limit:int -> Yojson.Safe.t
(** Durable compaction snapshot payload for
    [GET /api/v1/keepers/:name/compaction-snapshots]. Reads runtime manifests
    first, then keeper meta as a latest-only fallback, and emits only event
    metadata/token counts/provenance — never raw prompt or compacted context
    text. Exported for JSON contract tests. *)
