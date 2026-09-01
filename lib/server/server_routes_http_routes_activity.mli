(** Server_routes_http_routes_activity — HTTP routes for the activity
    graph dashboard surface.

    Wires operator-facing endpoints over the activity event stream.
    Daemon-side aggregation fibers are spawned under [~sw]; periodic
    rollups use [~clock]. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

type board_context_inference_target_source =
  | Explicit_target
  | Post_author

type board_context_inference_request = {
  post_id : string;
  target_keeper : string option;
}

val parse_board_context_inference_request :
  Yojson.Safe.t -> (board_context_inference_request, string) result

val resolve_board_context_inference_target :
  config:Workspace.config ->
  Board.post ->
  string option ->
  (string * board_context_inference_target_source, [ `Bad_request of string | `Internal_server_error of string ]) result

val wake_keepers_after_runtime_param_change :
  base_path:string ->
  param_key:string ->
  previous_interval_s:int ->
  new_interval_s:int ->
  Yojson.Safe.t option
(** For the Keeper cadence parameter, signals exact admitted [Running] or
    [Failing] sleepers only when the effective interval decreases. Lengthened,
    unchanged, in-flight, and inactive lanes remain explicit in the returned
    operator-visible summary. Other runtime parameters return [None]. *)

val mutate_runtime_param_with_effects :
  base_path:string ->
  param_key:string ->
  (unit -> (Runtime_params.json_change, string) result) ->
  (Runtime_params.json_change * (string * Yojson.Safe.t) list, string) result
(** Run a string-keyed parameter mutation and derive its wake effects as one
    serialized operation for the Keeper cadence key. Other keys remain
    independent and do not contend on the cadence side-effect lock. *)

val schedule_stamp_operator_actor :
  agent_name:string -> Yojson.Safe.t -> Yojson.Safe.t
(** Stamp the schedule tool's four actor fields (requested_by / scheduled_by,
    both human_operator) onto an argument object, replacing any actor claims
    the body carried: over HTTP the acting agent is the header-derived one,
    never the payload's. A non-object passes through untouched for the tool's
    own validation to refuse. *)
