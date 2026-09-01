(** Single-shot fetch of [/api/v1/dashboard/shell] + 5 s polling.

    Failed fetches keep the last shell snapshot but stamp it stale so the
    shared shell HUD can show freshness instead of presenting old chrome data
    as current. *)

open! Core
open Brr_io

let endpoint = "/api/v1/dashboard/shell"

let consecutive_failures = ref 0
let last_response = ref Overview_types.fixture

let store_success (response : Overview_types.response) : unit =
  consecutive_failures := 0;
  let response = { response with fetch_status = Overview_types.Fetch_fresh } in
  last_response := response;
  Bonsai.Expert.Var.set Overview_var.var response
;;

let store_failure (reason : string) : unit =
  consecutive_failures := !consecutive_failures + 1;
  let response =
    { !last_response with
      fetch_status =
        Overview_types.Fetch_stale
          { reason; consecutive_failures = !consecutive_failures }
    }
  in
  Bonsai.Expert.Var.set Overview_var.var response
;;

let parse_and_store (text : Jstr.t) : unit =
  match Yojson.Safe.from_string (Jstr.to_string text) with
  | json ->
    let response = Overview_types.response_of_yojson json in
    store_success response
  | exception exn ->
    store_failure ("parse failed: " ^ Exn.to_string exn)
;;

let run () : unit =
  let open Fut.Result_syntax in
  let work =
    let* response = Fetch.url (Jstr.v endpoint) in
    (* brr's fetch only errors on network failure — a 401 or 500 arrives as
       [Ok response] with an error body. Without this check that body goes
       through the permissive decoder and renders as a fresh, empty snapshot. *)
    let* () =
      if Fetch.Response.ok response
      then Fut.return ()
      else
        Fut.error
          (Printf.sprintf "HTTP %d %s"
             (Fetch.Response.status response)
             (Jstr.to_string (Fetch.Response.status_text response)))
    in
    Fetch.Body.text (Fetch.Response.as_body response)
  in
  Fut.await work (function
    | Ok text -> parse_and_store text
    | Error reason -> store_failure reason)
;;

let start_polling () : unit =
  let _id : Brr.G.timer_id = Brr.G.set_interval ~ms:5000 run in
  ()
;;
