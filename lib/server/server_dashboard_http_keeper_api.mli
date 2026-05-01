(** Server Dashboard HTTP — keeper-API surface.

    Implements the [/api/dashboard/keeper/<name>/...] family used by the
    operator dashboard.  Owns the route classifier, request body
    handlers, trajectory merge logic, and checkpoint inventory.  Most
    helpers are exported so the dashboard test suite can exercise the
    classifier and JSON shapes in isolation. *)

module Http = Http_server_eio
(** Alias used internally for the Eio HTTP server module. *)

(** {1 Route prefix and suffixes} *)

val keeper_api_prefix : string
(** [/api/dashboard/keeper] common prefix for every route below. *)

val keeper_suffix_tools : string
val keeper_suffix_config : string
val keeper_suffix_boot : string
val keeper_suffix_shutdown : string
val keeper_suffix_reset : string
val keeper_suffix_clear : string
val keeper_suffix_checkpoints : string
val keeper_suffix_directive : string

(** {1 Trajectory merge}

    The dashboard merges the on-disk turn trajectory with internal-history
    lines (per-turn snapshots from the keeper subprocess) so the operator
    sees both LLM messages and structural events in one feed. *)

val dedupe_tool_names : string list -> string list
(** Stable dedup preserving first occurrence. *)

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
  config:Coord.config ->
  trace_id:string -> Trajectory.trajectory_line list
(** Read the internal-history file for [trace_id] under [config]. *)

val merge_keeper_trace_lines :
  config:Coord.config ->
  trace_id:string ->
  Trajectory.trajectory_line list ->
  Trajectory.trajectory_line list
(** Merge [trajectory_lines] with the internal-history file in
    timestamp order, applying [dedupe_thinking_lines]. *)

(** {1 Tools route} *)

val keeper_tools_response_json :
  Keeper_types.keeper_meta -> Yojson.Safe.t
(** JSON shape returned by [GET /tools]. *)

val handle_keeper_tools_post :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Handle [POST /tools] (tool-grant edits). *)

(** {1 POST route classifier} *)

type keeper_post_route_kind =
  | Keeper_post_tools
  | Keeper_post_config
  | Keeper_post_boot
  | Keeper_post_shutdown
  | Keeper_post_reset
  | Keeper_post_clear
  | Keeper_post_checkpoints
  | Keeper_post_directive
  | Keeper_post_unknown
(** Sub-route kind for a [POST /api/dashboard/keeper/<name>/...] path. *)

val classify_keeper_post_route : string -> keeper_post_route_kind
(** Map a request path to its [keeper_post_route_kind]. *)

val keeper_path_ends_with : string -> string -> bool
(** [keeper_path_ends_with suffix path]: helper used by the classifier. *)

val extract_keeper_name_for_suffix : string -> string -> string
(** [extract_keeper_name_for_suffix suffix path] returns the keeper name
    from a path of shape [/api/dashboard/keeper/<name>/<suffix>]. *)

val is_keeper_checkpoints_get_path : string -> bool
(** [true] for [GET /api/dashboard/keeper/<name>/checkpoints] paths. *)

(** {1 Trajectory preview helpers} *)

val trim_to_opt : string -> string option
(** Trim and return [None] if empty. *)

val truncate_text : max_chars:int -> string -> string
(** Truncate [text] to [max_chars] (UTF-8 safe). *)

val latest_preview_of_messages :
  Agent_sdk.Types.message list -> string option
(** Latest assistant-text preview suitable for the dashboard list view. *)

val continuity_summary_of_messages :
  Agent_sdk.Types.message list -> string option
(** Latest [STATE]-derived continuity summary in the message history. *)

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
  Coord.config -> string -> [ `Not_found | `OK ] * Yojson.Safe.t
(** Inventory JSON for [GET /checkpoints]. *)

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
  config:Coord_utils.config -> name:String.t -> string -> unit
(** Re-read the keeper meta for [name] and update derived caches. *)

val invalidate_keeper_execution_surfaces :
  config:Coord_utils.config -> unit -> unit
(** Drop every cached keeper execution surface; called on server-wide
    reconfiguration. *)

(** {1 Action handlers} *)

val handle_keeper_config_post :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  Mcp_server.server_state ->
  string -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle [POST /config] (TOML edits). *)

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
  Mcp_server.server_state ->
  'a -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle [POST /directive] (operator directive injection). *)

val handle_keeper_get_subroutes :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Dispatch [GET /api/dashboard/keeper/<name>/<sub>] sub-routes
    (status / tools / checkpoints listing / etc.). *)
