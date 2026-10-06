(** Operator inventory only. No read below starts/stops/reconciles a Lane. *)
type selection =
  | Exact of Standalone_lane.t
  | Browser of Browser_lane.Lane_name.t
  | Machine of Machine_lane.t
  | Declaration of string
  | Manual_instance of { instance_id : string; incarnation : string }
type declaration =
  | Valid of Lane_addon_config.declaration
  | Invalid of string list
  | Absent
  | Unobserved
type machine_publication = No_screen | Stable | Running
type state =
  | Exact_state of Server_standalone_lane_projection.lane_configuration
  | Browser_clients of Browser_lane.activity * int
  | Browser_executor of Browser_lane.activity * bool
  | Machine_state of Machine_configuration.activity * machine_publication
  | Package_state of {
      declaration : declaration option;
      instances : Lane_addon_runtime.inventory_instance list;
    }
(** [Package_state.declaration=None] only for a manual attachment.
    Instances exclude confirmed Detached history. Complete declaration absence
    and confirmed cleanup remove a row; incomplete reads never prove absence.
    Machine activity and the last published screen are independent readings;
    disabled activity does not erase a stable or running publication. *)
type row = { id : string; label : string; purpose : string;
             selection : selection; state : state }
type t
val snapshot : config:Workspace.config -> t
val to_json : t -> Yojson.Safe.t
module For_testing : sig
  val package_rows : declarations:Lane_addon_config.snapshot ->
    instances:Lane_addon_runtime.inventory_instance list -> row list
  val row_to_json : row -> Yojson.Safe.t
end
