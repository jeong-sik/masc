(** Read-only Memory execution dependencies. A declared/serving route is not
    proof that a provider answered, a source was consumed or Memory committed.
    No result here admits or stops a Keeper turn. *)
type mode = Preflight | Live of Lane_addon_runtime.tool_execution_snapshot

type problem =
  | Configuration_unreadable of Lane_addon_config.issue list
  | Addon_unattached
  | Addon_off of string list
  | Multiple_installations of string list
  | Tool_missing of string
  | Output_not_selected of string
  | Route_unavailable of Lane_addon_exact.lane_unavailable
  | Export_unavailable of Keeper_librarian_addon.unavailable
  | Declaration_not_applied

type binding = { installation_id : string; output : string; route_table : string }
type state =
  | Disabled
  | Invalid_setting
  | Unavailable of binding option * problem
      (** No binding when a unique valid declaration has not been identified. *)
  | Configuration_admitted of binding
  | Serving of binding * Lane_addon_runtime.tool_execution

type t = (Keeper_librarian_addon.operation * state) list
val observe :
  setting:Env_config_keeper.KeeperMemoryOs.librarian_config_state ->
  declarations:Lane_addon_config.snapshot ->
  route:(Runtime_schema.addon_lane -> (unit, Lane_addon_exact.lane_unavailable) result) ->
  mode:mode -> t
(** Pure interpretation of captured declarations, route admission and live
    export observations. Tests use the same function as both real readers. *)
val snapshot : config:Workspace.config -> mode:[ `Preflight | `Live ] -> t
(** Loads only the configuration directory, off the server fiber, and reads the
    published route registry plus existing live worker cells. No full retained
    Add-on inventory or per-Keeper store traversal. *)
val to_json : t -> Yojson.Safe.t
(** Public diagnostic: configuration failures expose only categories and
    declaration identities. Raw parser messages and source paths remain in
    authenticated Lane configuration diagnostics. *)
