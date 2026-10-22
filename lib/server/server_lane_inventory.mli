(** Operator inventory only. No read below starts/stops/reconciles a Lane. *)
type selection =
  | Exact of Standalone_lane.t
  | Browser of Browser_lane.Lane_name.t
  | Machine of Machine_lane.t
  | Declaration of string
  | Manual_instance of { instance_id : string; incarnation : string }
(** Where a Lane Add-on exact output comes from: the package declares it, or
    runtime.toml has a [runtime.addon_exact_lanes] table for an output the
    package does not declare. *)
type exact_output_source = Declared | Table_only
type exact_output = {
  output : string;
  source : exact_output_source;
  configuration : Server_standalone_lane_projection.lane_configuration;
}
type declaration =
  | Valid of { declaration : Lane_addon_config.declaration; exact_outputs : exact_output list;
               application : Lane_addon_application.t }
      (** [exact_outputs]: the package's declared outputs in manifest order,
          then the tables runtime.toml has for outputs it does not declare.
          [application] comes from the host's exact reconciled declaration;
          missing, incomplete or mismatched observations remain Unknown. *)
  | Invalid of string list
  | Absent
  | Unobserved
type machine_publication = No_screen | Stable | Running | Publication_unavailable
(** What the browser Add-on's last published observation says for a
    built-in browser row. The server process holds no browser clients or
    executors of its own: since #44295 they live in the browser Add-on
    worker, so these rows read its cached observation. *)
type 'a browser_reading =
  | Browser_observed of 'a
  | Browser_addon_absent  (** No browser Add-on is declared. *)
  | Browser_addon_off  (** A browser Add-on is declared and switched off. *)
  | Browser_addon_not_running
      (** One is declared on and the runtime runs no installation of it. *)
  | Browser_addon_unavailable of string
type state =
  | Exact_state of Server_standalone_lane_projection.lane_configuration
  | Browser_clients of Browser_lane.activity * int browser_reading
  | Browser_executor of Browser_lane.activity * bool browser_reading
  | Machine_state of Machine_configuration.activity * machine_publication
  | Package_state of {
      declaration : declaration option;
      instances : Lane_addon_runtime.inventory_instance list;
    }
(** [Package_state.declaration=None] only for a manual attachment.
    Instances exclude confirmed Detached history. Complete declaration absence
    and confirmed cleanup remove a row; incomplete reads never prove absence.
    Machine activity comes from Runtime settings; screen publication comes from
    the attached shared Add-on. Failed/ambiguous observations are unavailable.
    Activity and the last published screen are independent readings;
    disabled activity does not erase a stable or running publication. *)
type row = { id : string; label : string; purpose : string;
             selection : selection; state : state }
type t
val snapshot : config:Workspace.config -> t
val to_json : t -> Yojson.Safe.t
module For_testing : sig
  val machine_publication : (Lane_addon_runtime.export_observation option, string) result -> machine_publication
  val browser_reading : declarations:Lane_addon_config.declaration list ->
    (Lane_addon_runtime.export_observation option, string) result ->
    Browser_addon_observation.published browser_reading
  val browser_state : activity:Browser_lane.activity -> Browser_addon_observation.published browser_reading ->
    Browser_lane.Lane_name.t -> state
  val package_rows : declarations:Lane_addon_config.snapshot ->
    instances:Lane_addon_runtime.inventory_instance list ->
    applications:Lane_addon_runtime.configuration_application list ->
    exact_outputs:(Lane_addon_config.declaration -> exact_output list) -> row list
  val exact_outputs :
    configuration:(Runtime_schema.addon_lane -> Server_standalone_lane_projection.lane_configuration) ->
    tables:(declaration_id:string -> string list) -> Lane_addon_config.declaration -> exact_output list
  val row_to_json : row -> Yojson.Safe.t
end
