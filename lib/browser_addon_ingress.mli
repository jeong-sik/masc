(** Trusted native-host ingress after workspace lane-token authentication.
    Existing client IDs stay bound to their first worker across server restarts.
    No call falls back to a built-in queue or a replacement worker. *)
type unavailable =
  | No_addon
  | Ambiguous_addons
  | Observation_unavailable
  | Addon_unavailable
  | Registration_unconfirmed of string
  | Worker_unavailable of string
  | Worker_refused of string
(** Why no Add-on can answer now. A native host reads [unavailable_to_wire];
    the string payloads are diagnostics from the registration store or the
    worker and are not part of the code. *)

val unavailable_to_wire : unavailable -> string
(** A code of lower-case letters, digits and underscores, at most 64
    characters: the form a native host accepts as a refusal reason. *)

(** One operator sentence for the cause. The response carries it in [detail];
    it is prose and never a code. *)
val unavailable_message : unavailable -> string

type error = Registration_refused of Browser_lane.registration_refusal
  | Unavailable of unavailable | Outcome_unknown of string
val poll : config:Workspace.config -> client:Browser_lane.client_info -> window_sec:float ->
  (Browser_lane.issued option, error) result
val deliver : config:Workspace.config -> client:Browser_lane.client_info -> id:string ->
  payload:Yojson.Safe.t -> (unit, error) result
val disconnect : config:Workspace.config -> client:Browser_lane.client_info -> (unit, error) result
