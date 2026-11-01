(** The gate the HTTP/2 gateway runs for each kind of route, and what it does
    with the answer of the HTTP/1 router. *)

open Alcotest
open Masc
module Gate = Server_h2_route_gate
module Router = Http_server_eio.Router

let admin = Masc_domain.CanAdmin

let gate_outcome = function
  | Ok Gate.Open -> "open"
  | Ok Gate.Public_read -> "public_read"
  | Ok Gate.Read_auth -> "read_auth"
  | Ok (Gate.Token_permission p) ->
    "token_permission:" ^ Masc_domain.permission_to_string p
  | Error Gate.No_route -> "refused:no_route"
  | Error Gate.Wrong_method -> "refused:wrong_method"
  | Error (Gate.Kind_not_served _) -> "refused:kind_not_served"
  | Error (Gate.Actor_not_provided _) -> "refused:actor_not_provided"
;;

let actor_outcome = function
  | Ok p -> "permission:" ^ Masc_domain.permission_to_string p
  | Error refusal -> gate_outcome (Error refusal)
;;

(* kind, what the arm without an actor gets, what the arm with an actor gets *)
let expected : (string * Route_access.t * string * string) list =
  [ "always_public", Route_access.Always_public, "open", "refused:actor_not_provided"
  ; "public_read", Route_access.Public_read, "public_read", "refused:actor_not_provided"
  ; "read_auth", Route_access.Read_auth, "read_auth", "refused:actor_not_provided"
  ; ( "token_permission"
    , Route_access.Token_permission admin
    , "token_permission:CanAdmin"
    , "permission:CanAdmin" )
  ; ( "permission"
    , Route_access.Permission admin
    , "refused:kind_not_served"
    , "refused:kind_not_served" )
  ; ( "private_token_permission"
    , Route_access.Private_token_permission admin
    , "refused:kind_not_served"
    , "refused:kind_not_served" )
  ; ( "tool"
    , Route_access.Tool { tool_name = "masc_status" }
    , "refused:kind_not_served"
    , "refused:kind_not_served" )
  ; ( "tool_observation"
    , Route_access.Tool_observation { tool_name = "masc_status" }
    , "refused:kind_not_served"
    , "refused:kind_not_served" )
  ; ( "tool_actor"
    , Route_access.Tool_actor { tool_name = "masc_status" }
    , "refused:kind_not_served"
    , "refused:kind_not_served" )
  ; ( "self_authenticated mcp_transport"
    , Route_access.Self_authenticated Route_access.Mcp_transport
    , "open"
    , "refused:actor_not_provided" )
  ; ( "self_authenticated oauth_protocol"
    , Route_access.Self_authenticated Route_access.Oauth_protocol
    , "open"
    , "refused:actor_not_provided" )
  ; ( "self_authenticated websocket_upgrade"
    , Route_access.Self_authenticated Route_access.Websocket_upgrade
    , "open"
    , "refused:actor_not_provided" )
  ; ( "self_authenticated browser_lane"
    , Route_access.Self_authenticated Route_access.Browser_lane
    , "refused:kind_not_served"
    , "refused:kind_not_served" )
  ; ( "self_authenticated loopback_dev_token"
    , Route_access.Self_authenticated Route_access.Loopback_dev_token
    , "refused:kind_not_served"
    , "refused:kind_not_served" )
  ; ( "self_authenticated subpath_dispatch"
    , Route_access.Self_authenticated Route_access.Subpath_dispatch
    , "refused:kind_not_served"
    , "refused:kind_not_served" )
  ]
;;

let test_plan_for_every_kind () =
  List.iter
    (fun (name, kind, want_gate, want_actor) ->
       check string (name ^ ", no actor") want_gate (gate_outcome (Gate.plan kind));
       check string (name ^ ", actor") want_actor (actor_outcome (Gate.plan_actor kind)))
    expected
;;

let handler : Http_server_eio.request_handler = fun _request _reqd -> ()
let state_handler : Server_route.state_handler = fun _state _request _reqd -> ()

let router =
  Router.create ()
  |> Server_route.get Server_route.Always_public "/open" handler
  |> Server_route.get Server_route.Always_public "/only-get" handler
  |> Server_route.prefix_get Server_route.Always_public "/under/" handler
  |> Server_route.get Server_route.Public_read "/read" state_handler
;;

let resolve meth target =
  gate_outcome
    (Result.bind
       (Gate.access_of_resolution (Router.resolve router (Httpun.Request.create meth target)))
       Gate.plan)
;;

let test_resolution () =
  check string "an exact route" "open" (resolve `GET "/open");
  check string "a prefix route" "open" (resolve `GET "/under/deep/path");
  check string "the query is not part of the path" "open" (resolve `GET "/open?x=1");
  check string "the kind the registration gave" "public_read" (resolve `GET "/read");
  check string "a path the router does not have" "refused:no_route" (resolve `GET "/missing");
  check string "a method the path does not have" "refused:wrong_method" (resolve `POST "/only-get")
;;

let () =
  run
    "server_h2_route_gate"
    [ "plan", [ test_case "every kind" `Quick test_plan_for_every_kind ]
    ; "resolution", [ test_case "what the router answers" `Quick test_resolution ]
    ]
;;
