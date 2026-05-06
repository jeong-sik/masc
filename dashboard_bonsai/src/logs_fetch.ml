(** Single-shot fetch of [/api/v1/dashboard/logs] + 3 s polling.

    Uses brr's Fetch API (which returns [Fut.or_error]) and updates
    [Logs_var.var] on success. Failed fetches keep the last good
    response in the Var but stamp it stale, so the logs HUD can show
    freshness instead of silently rendering old rows as current. *)

open! Core
open Brr_io

let endpoint = "/api/v1/dashboard/logs?limit=200&level=INFO"

let consecutive_failures = ref 0
let last_response = ref Logs_types.fixture

let store_success (response : Logs_types.response) : unit =
  consecutive_failures := 0;
  let response = { response with fetch_status = Logs_types.Fetch_fresh } in
  last_response := response;
  Bonsai.Expert.Var.set Logs_var.var response
;;

let store_failure (reason : string) : unit =
  consecutive_failures := !consecutive_failures + 1;
  let response =
    { !last_response with
      fetch_status =
        Logs_types.Fetch_stale
          { reason; consecutive_failures = !consecutive_failures }
    }
  in
  Bonsai.Expert.Var.set Logs_var.var response
;;

let parse_and_store (text : Jstr.t) : unit =
  match Yojson.Safe.from_string (Jstr.to_string text) with
  | json ->
    let response = Logs_types.response_of_yojson json in
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

(** Register a 3 s polling loop via [window.setInterval]. Runs forever for the
    lifetime of the page. The returned [timer_id] is ignored for now because
    the page survives until full reload. *)
let start_polling () : unit =
  let _id : Brr.G.timer_id = Brr.G.set_interval ~ms:3000 run in
  ()
;;
