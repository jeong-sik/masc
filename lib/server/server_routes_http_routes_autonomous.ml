(* Autonomous phase taxonomy HTTP surface — Cycle 27 / Tier D2.
   See server_routes_http_routes_autonomous.mli for design. *)

open Server_utils
open Server_auth
module Http = Http_server_eio
module P = Autonomous.Autonomous_phase

let phases_response () =
  let phases =
    List.map
      (fun s -> `Assoc [ ("tag", `String s); ("symbol", `String s) ])
      P.all_symbols
  in
  `Assoc [ ("count", `Int (List.length phases)); ("phases", `List phases) ]

let transitions_response () =
  let transitions =
    List.map
      (fun s -> `Assoc [ ("tag", `String s); ("symbol", `String s) ])
      P.Transition.all_symbols
  in
  `Assoc
    [
      ("count", `Int (List.length transitions));
      ("transitions", `List transitions);
    ]

let add_routes router =
  router
  |> Http.Router.prefix_get "/api/v1/autonomous/phases"
       (fun request reqd ->
         with_public_read
           (fun _state _req reqd ->
             let json = phases_response () in
             respond_public_read_json ~status:`OK request reqd
               (Yojson.Safe.to_string json))
           request reqd)
  |> Http.Router.prefix_get "/api/v1/autonomous/transitions"
       (fun request reqd ->
         with_public_read
           (fun _state _req reqd ->
             let json = transitions_response () in
             respond_public_read_json ~status:`OK request reqd
               (Yojson.Safe.to_string json))
           request reqd)
