module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_misc_transport — Transport and WebSocket tool handlers.

    Extracted from tool_misc.ml to reduce god file size.
    Contains HTTP/WS/gRPC discovery and status handlers.

    @since 2.188.0 — God file decomposition Phase 1 *)

type tool_result = Tool_result.t

let env_flag_enabled name =
  match Sys.getenv_opt name with
  | None -> false
  | Some raw ->
      let v = String.trim raw |> String.lowercase_ascii in
      String.equal v "1" || String.equal v "true" || String.equal v "yes" || String.equal v "y" || String.equal v "on"

(* ================================================================ *)
(* Handlers                                                         *)
(* ================================================================ *)

let handle_transport_status ~tool_name ~start_time _args : tool_result =
  let ctx =
    Transport_read_model.context_from_env
      ~allow_legacy_accept:(env_flag_enabled "MASC_ALLOW_LEGACY_ACCEPT") ()
  in
  let json = Transport_read_model.transport_status_json ctx in
  Tool_result.ok ~tool_name ~start_time:start_time (Yojson.Safe.to_string json)

let handle_websocket_discovery ~tool_name ~start_time _args : tool_result =
  let ctx =
    Transport_read_model.context_from_env
      ~allow_legacy_accept:(env_flag_enabled "MASC_ALLOW_LEGACY_ACCEPT") ()
  in
  let json = Transport_read_model.websocket_discovery_json ctx in
  Tool_result.ok ~tool_name ~start_time:start_time (Yojson.Safe.to_string json)
