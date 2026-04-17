(** HTTP routes for the attribution gate-chain dashboard.

    Reads from the in-process ring buffer in {!Dashboard_attribution}.

    - [GET /api/v1/attribution/recent?gate=X&limit=N] — latest events,
      newest first. [gate] absent merges across gates.
    - [GET /api/v1/attribution/summary] — per-gate outcome counts over the
      current ring window, for the dashboard graph nodes. *)

open Server_auth

module Http = Http_server_eio
module DA = Dashboard_attribution
module A = Attribution

let trimmed_query_param req key =
  match Server_utils.query_param req key |> Option.map String.trim with
  | Some v when v <> "" -> Some v
  | _ -> None

let event_json ((attr, recorded_at) : A.t * float) : Yojson.Safe.t =
  `Assoc
    [
      ("attribution", A.to_yojson attr);
      ("recorded_at", `Float recorded_at);
    ]

let recent_json ?gate ?limit () : Yojson.Safe.t =
  let events = DA.recent ?gate ?limit () in
  `Assoc
    [
      ("events", `List (List.map event_json events));
      ("count", `Int (List.length events));
    ]

let gate_summary_json (s : DA.gate_summary) : Yojson.Safe.t =
  `Assoc
    [
      ("gate", `String s.gate);
      ("passed", `Int s.passed);
      ("policy_failed", `Int s.policy_failed);
      ("transition_blocked", `Int s.transition_blocked);
      ("partial_pass", `Int s.partial_pass);
      ("total", `Int s.total);
    ]

let summary_json () : Yojson.Safe.t =
  `Assoc
    [ ("gates", `List (List.map gate_summary_json (DA.summary ()))) ]

let add_routes router =
  router
  |> Http.Router.get "/api/v1/attribution/recent" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let gate = trimmed_query_param req "gate" in
         let limit =
           match trimmed_query_param req "limit" with
           | Some s -> int_of_string_opt s
           | None -> None
         in
         let json = recent_json ?gate ?limit () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/attribution/summary" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = summary_json () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
