(** Single-shot fetch of [/api/v1/dashboard/logs].

    Uses brr's Fetch API (which returns [Fut.or_error]) and updates
    [Logs_var.var] on success. Errors are dropped silently for now — a
    Phase 1c iteration will surface them to the view layer. Polling is
    also Phase 1c. *)

open! Core
open Brr_io

let endpoint = "/api/v1/dashboard/logs?limit=200&level=INFO"

let parse_and_store (text : Jstr.t) : unit =
  match Yojson.Safe.from_string (Jstr.to_string text) with
  | json ->
    let response = Logs_types.response_of_yojson json in
    Bonsai.Expert.Var.set Logs_var.var response
  | exception _ -> ()
;;

let run () : unit =
  let open Fut.Result_syntax in
  let work =
    let* response = Fetch.url (Jstr.v endpoint) in
    Fetch.Body.text (Fetch.Response.as_body response)
  in
  Fut.await work (function
    | Ok text -> parse_and_store text
    | Error _ -> ())
;;

(** Register a 3 s polling loop via [window.setInterval]. Runs forever for the
    lifetime of the page — Phase 1c should swap this for a Bonsai
    [Clock.every] once the Fut→Effect bridge lands, so polling cancels with
    component unmount. The returned [timer_id] is ignored for now because the
    page survives until full reload. *)
let start_polling () : unit =
  let _id : Brr.G.timer_id = Brr.G.set_interval ~ms:3000 run in
  ()
;;

