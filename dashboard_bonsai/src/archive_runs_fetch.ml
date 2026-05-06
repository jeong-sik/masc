(** Single-shot fetch of [/api/v1/autoresearch/loops] + 5 s polling.

    Archive runs are not as time-sensitive as the logs tab, so polling is
    slower (5 s vs 3 s). Failed fetches keep the previous response but stamp
    it stale, so the UI does not flicker and does not present old archive
    rows as current. *)

open! Core
open Brr_io

let endpoint = "/api/v1/autoresearch/loops?limit=200"

let consecutive_failures = ref 0
let last_response = ref Archive_runs_types.fixture

let store_success (response : Archive_runs_types.response) : unit =
  consecutive_failures := 0;
  let response =
    { response with fetch_status = Archive_runs_types.Fetch_fresh }
  in
  last_response := response;
  Bonsai.Expert.Var.set Archive_runs_var.var response
;;

let store_failure (reason : string) : unit =
  consecutive_failures := !consecutive_failures + 1;
  let response =
    { !last_response with
      fetch_status =
        Archive_runs_types.Fetch_stale
          { reason; consecutive_failures = !consecutive_failures }
    }
  in
  Bonsai.Expert.Var.set Archive_runs_var.var response
;;

let parse_and_store (text : Jstr.t) : unit =
  match Yojson.Safe.from_string (Jstr.to_string text) with
  | json ->
    let response = Archive_runs_types.response_of_yojson json in
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
  let _id : Brr.G.timer_id = Brr.G.set_interval ~ms:5000 run in
  ()
;;
