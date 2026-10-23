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
(** What one browser worker reported in its [Snapshot] reply, read by the host
    when it chooses. Executor registration alone never establishes an open
    browser. *)
val choose : ?required_actions:Browser_capabilities.operation list ->
  verb:Browser_lane.verb -> bound:bool -> snapshot:snapshot -> preference ->
  (selected, error) result
(** Pure selection. Automatic requests containing a tab/document binding must
    first provide its exact browser identity. Explicit routes never fall back. *)
val bound : Browser_lane.verb -> bool
(** The verb addresses a tab or document a browser already showed, so an
    automatic choice could land on another browser. *)
type browser = Owned_automation | Owned_stagehand | Connected of Browser_lane.client_info
(** The concrete browser a chosen route names in the snapshot. *)
val target : verb:Browser_lane.verb -> snapshot:snapshot -> Browser_lane.route ->
  (browser, Browser_lane.selection_error) result
(** The browser the route names, with the refusals a worker gives for the
    same route: a lane that is off, a client that is not connected, and a live
    lane without a client ID while none or several are connected. The worker
    checks the route again before it dispatches. *)
val require : snapshot:snapshot -> Browser_capabilities.operation list -> browser -> (unit, error) result
(** Check the chosen browser's implemented operations. Explicit routes remain
    explicit even if unsupported. *)
val bind : selected -> browser -> selected
(** Carry the chosen browser's concrete identity into receipts. An explicit
    live lane without a client ID becomes the client the snapshot named. *)
val backend_of_browser : browser -> Browser_capabilities.backend
val reason_to_wire : reason -> string
val reason_of_wire : string -> reason option
val to_json : selected -> Yojson.Safe.t
val error_to_json : error -> Yojson.Safe.t
val error_message : error -> string
