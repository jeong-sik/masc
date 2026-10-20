(** Trusted native-host ingress after workspace lane-token authentication.
    Existing client IDs stay bound to their first worker across server restarts.
    No call falls back to a built-in queue or a replacement worker. *)
type error = Registration_refused of Browser_lane.registration_refusal
  | Unavailable of string | Outcome_unknown of string
val poll : config:Workspace.config -> client:Browser_lane.client_info -> window_sec:float ->
  (Browser_lane.issued option, error) result
val deliver : config:Workspace.config -> client:Browser_lane.client_info -> id:string ->
  payload:Yojson.Safe.t -> (unit, error) result
val disconnect : config:Workspace.config -> client:Browser_lane.client_info -> (unit, error) result
