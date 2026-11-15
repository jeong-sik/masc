(** Read-only Memory execution dependencies. A declared/serving route is not
    proof that a provider answered, a source was consumed or Memory committed.
    No result here admits or stops a Keeper turn. *)
type mode = Preflight | Live of Lane_addon_runtime.tool_execution_snapshot

type unreadable_source =
  | Lane_directory  (** The Lane directory itself could not be read. *)
  | Declaration_file of string
      (** The file's name inside the Lane directory, without the directory. *)
type unreadable = { source : unreadable_source; issue : Lane_addon_config.issue }

type problem =
  | Configuration_unreadable of unreadable list
      (** Every issue of the reading, each with the file it is about. One
          unreadable declaration is enough: it may be the Librarian's. *)
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
(** Public diagnostic: configuration failures expose only categories,
    declaration identities and each unreadable declaration's file name inside
    the Lane directory. Raw parser messages and the directory's own path remain
    in authenticated Lane configuration diagnostics. *)
