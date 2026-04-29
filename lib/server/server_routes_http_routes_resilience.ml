(* Resilience taxonomy HTTP surface — Cycle 27 / Tier D3.
   See server_routes_http_routes_resilience.mli for design. *)

open Server_utils
open Server_auth
module Http = Http_server_eio
module D = Resilience.Degradation

let level_description = function
  | D.Tag_l1 ->
      "L1 — full execution. No degradation."
  | D.Tag_l2 ->
      "L2 — reduced quality. Operator notified, confidence \
       degraded."
  | D.Tag_l3 ->
      "L3 — skeleton output. External tools blocked, partial \
       success only."
  | D.Tag_l4 ->
      "L4 — fallback. Permanent failure path, no retry."

let level_rank = function
  | D.Tag_l1 -> 1
  | D.Tag_l2 -> 2
  | D.Tag_l3 -> 3
  | D.Tag_l4 -> 4

let levels_response () =
  let entries =
    List.map
      (fun tag ->
        let symbol = D.level_tag_to_string tag in
        `Assoc
          [
            ("tag", `String symbol);
            ("symbol", `String symbol);
            ("rank", `Int (level_rank tag));
            ("description", `String (level_description tag));
          ])
      D.all_level_tags
  in
  `Assoc
    [ ("count", `Int (List.length entries)); ("levels", `List entries) ]

let strategies_static =
  [
    ( "Retry",
      "Recoverable error — retry with the same or escalated \
       parameters." );
    ( "Fallback",
      "Permanent error in the primary path — switch to a known \
       fallback (cache, alternate provider, degraded payload)." );
    ( "Handoff",
      "Multi-actor coordination required — escalate to a peer \
       keeper or operator." );
    ( "Abort",
      "Unrecoverable — abandon the turn, surface the failure to \
       the operator." );
  ]

let strategies_response () =
  let entries =
    List.map
      (fun (tag, desc) ->
        `Assoc [ ("tag", `String tag); ("description", `String desc) ])
      strategies_static
  in
  `Assoc
    [
      ("count", `Int (List.length entries));
      ("strategies", `List entries);
    ]

let add_routes router =
  router
  |> Http.Router.prefix_get "/api/v1/resilience/levels"
       (fun request reqd ->
         with_public_read
           (fun _state _req reqd ->
             let json = levels_response () in
             respond_public_read_json ~status:`OK request reqd
               (Yojson.Safe.to_string json))
           request reqd)
  |> Http.Router.prefix_get "/api/v1/resilience/strategies"
       (fun request reqd ->
         with_public_read
           (fun _state _req reqd ->
             let json = strategies_response () in
             respond_public_read_json ~status:`OK request reqd
               (Yojson.Safe.to_string json))
           request reqd)
