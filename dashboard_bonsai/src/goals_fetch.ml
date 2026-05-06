(** Single-shot fetch of [/api/v1/dashboard/goals] + 10 s polling.

    Goals are config-driven — they change slowly. 10 s polling keeps the
    tab fresh without hammering the endpoint. Failed fetches keep the last
    good response in the Var but stamp it stale, matching Logs_fetch and
    Keepers_fetch so stale goal data is visible instead of silently current. *)

open! Core
open Brr_io

let endpoint = "/api/v1/dashboard/goals"

let consecutive_failures = ref 0
let last_response = ref Goals_types.fixture

let store_success (response : Goals_types.response) : unit =
  consecutive_failures := 0;
  let response = { response with fetch_status = Goals_types.Fetch_fresh } in
  last_response := response;
  Bonsai.Expert.Var.set Goals_var.var response
;;

let store_failure (reason : string) : unit =
  consecutive_failures := !consecutive_failures + 1;
  let response =
    { !last_response with
      fetch_status =
        Goals_types.Fetch_stale
          { reason; consecutive_failures = !consecutive_failures }
    }
  in
  Bonsai.Expert.Var.set Goals_var.var response
;;

let parse_and_store (text : Jstr.t) : unit =
  match Yojson.Safe.from_string (Jstr.to_string text) with
  | json ->
    let response = Goals_types.response_of_yojson json in
    store_success response
  | exception exn ->
    store_failure ("parse failed: " ^ Exn.to_string exn)
;;

let run () : unit =
  let open Fut.Result_syntax in
  let work =
    let* response = Fetch.url (Jstr.v endpoint) in
    Fetch.Body.text (Fetch.Response.as_body response)
  in
  Fut.await work (function
    | Ok text -> parse_and_store text
    | Error _ -> store_failure "fetch failed")
;;

let start_polling () : unit =
  let _id : Brr.G.timer_id = Brr.G.set_interval ~ms:10000 run in
  ()
;;
