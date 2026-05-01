open Base
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

(** Tool_misc_transport — Transport, WebSocket, and WebRTC tool handlers.

    Extracted from tool_misc.ml to reduce god file size.
    Contains HTTP/WS/gRPC/WebRTC discovery and status handlers.

    @since 2.188.0 — God file decomposition Phase 1 *)

open Tool_args

type tool_result = bool * string

(* ================================================================ *)
(* Local helpers (duplicated from tool_misc to avoid circular deps) *)
(* ================================================================ *)

let encode_string_list values =
  `List (List.map (fun value -> `String value) values)

let pretty_json_string raw =
  try Yojson.Safe.from_string raw |> Yojson.Safe.pretty_to_string
  with Yojson.Json_error _ -> raw

let env_flag_enabled name =
  match Sys.getenv_opt name with
  | None -> false
  | Some raw ->
      let v = String.trim raw |> String.lowercase_ascii in
      String.equal v "1" || String.equal v "true" || String.equal v "yes" || String.equal v "y" || String.equal v "on"

(* ================================================================ *)
(* Handlers                                                         *)
(* ================================================================ *)

let handle_transport_status _args : tool_result =
  let ctx =
    Transport_read_model.context_from_env
      ~allow_legacy_accept:(env_flag_enabled "MASC_ALLOW_LEGACY_ACCEPT") ()
  in
  let json = Transport_read_model.transport_status_json ctx in
  (true, Yojson.Safe.to_string json)

let handle_websocket_discovery _args : tool_result =
  let ctx =
    Transport_read_model.context_from_env
      ~allow_legacy_accept:(env_flag_enabled "MASC_ALLOW_LEGACY_ACCEPT") ()
  in
  let json = Transport_read_model.websocket_discovery_json ctx in
  (true, Yojson.Safe.to_string json)

let handle_webrtc_offer args : tool_result =
  if not (Server_webrtc_transport.is_enabled ()) then
    error_result "webrtc transport disabled"
  else
  let*! agent_name = get_string_required args "agent_name" in
  let ice_candidates = get_string_list args "ice_candidates" in
  let fields =
    [
      ("agent_name", `String agent_name);
      ("ice_candidates", encode_string_list ice_candidates);
    ]
    @
    match get_string_opt args "dtls_fingerprint" with
    | Some fingerprint ->
        [ ("dtls_fingerprint", `String fingerprint) ]
    | None -> []
  in
  match
    Server_webrtc_transport.handle_offer_request
      (Yojson.Safe.to_string (`Assoc fields))
  with
  | Ok body -> (true, pretty_json_string body)
  | Error msg -> error_result msg

let handle_webrtc_answer args : tool_result =
  if not (Server_webrtc_transport.is_enabled ()) then
    error_result "webrtc transport disabled"
  else
  let*! offer_id = get_string_required args "offer_id" in
  let*! agent_name = get_string_required args "agent_name" in
  let ice_candidates = get_string_list args "ice_candidates" in
  let body =
    `Assoc
      [
        ("offer_id", `String offer_id);
        ("agent_name", `String agent_name);
        ("ice_candidates", encode_string_list ice_candidates);
      ]
    |> Yojson.Safe.to_string
  in
  match Server_webrtc_transport.handle_answer_request body with
  | Ok response -> (true, pretty_json_string response)
  | Error msg -> error_result msg
