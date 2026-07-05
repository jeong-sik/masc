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

val board_context_inference_target_source_to_string :
  board_context_inference_target_source -> string

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
