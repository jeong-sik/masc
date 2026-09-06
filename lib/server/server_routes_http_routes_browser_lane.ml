(* HTTP routes for the browser lane (docs/design/browser-lane.md, task-1382).

   POST /browser-lane/poll    — x-lane: one command {id, verb, args}, or an
                                empty window the host loops on
   POST /browser-lane/result  — {id, ok, data | error}: resolves the waiting
                                tool call

   Auth is a lane token, not a dashboard session: the host process is not a
   person. The token lives at <base>/.masc/browser-lane/token (0600, written
   by connectors/browser/install-host.sh). No token file means the lane is
   not installed, and every request fails closed — port 8935 is what the
   public tunnel points at, so an unauthenticated lane would publish the
   user's browser to the internet. *)

open Server_auth
module Http = Http_server_eio

let lane_token_path () =
  Env_config_core.resolve_against_base_path ".masc/browser-lane/token"
;;

let lane_token () =
  match
    In_channel.with_open_bin (lane_token_path ()) (fun ic ->
        String.trim (In_channel.input_all ic))
  with
  | token when String.length token >= 16 -> Some token
  | _ -> None
  | exception Sys_error _ -> None
;;

(* Fail closed: no installed token, or a wrong one, is the same refusal. *)
let lane_authorized request =
  match lane_token () with
  | None -> false
  | Some token ->
    Server_mcp_transport_http_session.get_header_any_case
      request.Httpun.Request.headers
      "x-lane-token"
    = Some token
;;

let object_of_body body =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> Ok fields
  | other -> Error (Printf.sprintf "body must be a JSON object, got: %s" (Yojson.Safe.to_string other))
  | exception Yojson.Json_error message -> Error ("invalid JSON: " ^ message)
;;

let error_json message : Yojson.Safe.t = `Assoc [ "ok", `Bool false; "error", `String message ]

let lane_of_request request =
  match
    Server_mcp_transport_http_session.get_header_any_case
      request.Httpun.Request.headers
      "x-lane"
  with
  | Some lane when List.mem lane Browser_lane.allowed_lane_names -> Ok lane
  | Some other -> Error ("unknown lane: " ^ other)
  | None -> Error "x-lane header is required"
;;

(* A poll holds one command for the window. The answer is flat
   {id, verb, args} — the exact shape the host consumes — so the lane
   protocol has one wire form everywhere. *)
let poll_answer_json (issued : Browser_lane.issued) : Yojson.Safe.t =
  match issued.Browser_lane.verb_json with
  | `Assoc (("verb", `String verb) :: ("args", args) :: _) ->
    `Assoc [ ("id", `String issued.Browser_lane.id); ("verb", `String verb); ("args", args) ]
  | other ->
    `Assoc
      [ ("id", `String issued.Browser_lane.id)
      ; ("error", `String ("malformed verb envelope: " ^ Yojson.Safe.to_string other))
      ]
;;

let add_routes router =
  let refuse request reqd =
    respond_json_value_with_cors ~status:`Forbidden request reqd
      (error_json "lane token required")
  in
  router
  |> Http.Router.post "/browser-lane/poll" (fun request reqd ->
       if not (lane_authorized request) then refuse request reqd
       else
         match lane_of_request request with
         | Error message ->
           respond_json_value_with_cors ~status:`Bad_request request reqd (error_json message)
         | Ok lane -> (
           match Browser_lane.take_command ~lane_name:lane ~window_sec:25. with
           | Error message ->
             respond_json_value_with_cors ~status:`Bad_request request reqd (error_json message)
           | Ok None ->
             respond_json_value_with_cors request reqd (`Assoc [ ("ok", `Bool true); ("empty", `Bool true) ])
           | Ok (Some issued) ->
             respond_json_value_with_cors request reqd (poll_answer_json issued)))
  |> Http.Router.post "/browser-lane/result" (fun request reqd ->
       if not (lane_authorized request) then refuse request reqd
       else
         Http.Request.read_body_async reqd (fun body ->
             let respond ~status fields =
               respond_json_value_with_cors ~status request reqd (`Assoc (("ok", `Bool true) :: fields))
             in
             match object_of_body body with
             | Error message ->
               respond_json_value_with_cors ~status:`Bad_request request reqd (error_json message)
             | Ok fields ->
               (match lane_of_request request with
               | Error message ->
                 respond_json_value_with_cors ~status:`Bad_request request reqd (error_json message)
               | Ok lane -> (
                 match List.assoc_opt "id" fields with
                 | Some (`String id) ->
                   let payload =
                     `Assoc
                       [ ("ok", match List.assoc_opt "ok" fields with Some (`Bool v) -> `Bool v | _ -> `Bool false)
                       ; ("data", Option.value (List.assoc_opt "data" fields) ~default:`Null)
                       ; ("error", Option.value (List.assoc_opt "error" fields) ~default:`Null)
                       ]
                   in
                   (match Browser_lane.deliver_result ~lane_name:lane ~id ~payload with
                    | Ok () -> respond ~status:`OK []
                    | Error message ->
                      respond_json_value_with_cors ~status:`Bad_request request reqd (error_json message))
                 | _ ->
                   respond_json_value_with_cors ~status:`Bad_request request reqd
                     (error_json "id is required")))))
;;
