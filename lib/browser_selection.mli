(** Browser choice before dispatch. Selection performs no browser command and
    grants no authority: the selected route is rechecked at normal admission. *)
type preference = Automatic | Exact of Browser_lane.route
type reason = Explicit_browser | Existing_login | Existing_work_session
  | Preferred_work_browser | Compatible_work_browser | Available_connected_browser
type selected = { route : Browser_lane.route; reason : reason }
type error = Binding_required | No_available_browser
  | Ambiguous_browsers of Browser_lane.route list
  | Required_actions_unavailable of { required : Browser_capabilities.operation list;
      candidates : (Browser_lane.route * Browser_capabilities.operation list) list }
  | Unsupported_required_actions of { route : Browser_lane.route;
      missing : Browser_capabilities.operation list }
type work_browser =
  { activity : Browser_lane.activity; registered : bool
  ; session : Browser_lane.session_observation; locate : bool }
(** [locate] observes the installed model consumer and selected output, not
    merely the presence of a driver or a configured provider. For Chrome this
    is the shared Stagehand consumer for observe, act and extract; task-required
    sentence actions also require it before discovery or session creation. *)
type snapshot =
  { live_activity : Browser_lane.activity; live_clients : Browser_lane.client_info list
  ; automation : work_browser; stagehand : work_browser }
val snapshot : unit -> snapshot
(** Read current connection/activity and nonblocking owned-session observations.
    Executor registration alone never establishes an open browser. *)
val choose : ?required_actions:Browser_capabilities.operation list ->
  verb:Browser_lane.verb -> bound:bool -> snapshot:snapshot -> preference ->
  (selected, error) result
(** Pure selection. Automatic requests containing a tab/document binding must
    first provide its exact browser identity. Explicit routes never fall back. *)
val resolve : ?required_actions:Browser_capabilities.operation list ->
  verb:Browser_lane.verb -> bound:bool -> preference -> (selected, error) result
val require_target : Browser_capabilities.operation list -> Browser_lane.target -> (unit, error) result
(** Check the admitted concrete target without transferring its ownership or
    dispatching browser input. Explicit routes remain explicit even if unsupported. *)
val bind_target : selected -> Browser_lane.target -> selected
(** Carry the admitted browser's concrete identity into receipts. An explicit
    live lane without a client ID becomes the client admission actually chose. *)
val reason_to_wire : reason -> string
val reason_of_wire : string -> reason option
val to_json : selected -> Yojson.Safe.t
val error_to_json : error -> Yojson.Safe.t
val error_message : error -> string
