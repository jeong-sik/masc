(** Single-shot fetch of [/dashboard/b/api/keepers/summary] + 3 s polling.

    Mirrors [Logs_fetch] — same Fut-based Fetch API, same interval strategy.
    Errors are currently dropped (the previous response stays in the Var so
    views don't flicker). Phase 1c will surface a "stale" indicator when
    multiple fetches in a row fail. *)

open! Core
open Brr_io

let endpoint = "/dashboard/b/api/keepers/summary"

let parse_and_store (text : Jstr.t) : unit =
  match Yojson.Safe.from_string (Jstr.to_string text) with
  | json ->
    let response = Keepers_types.response_of_yojson json in
    Bonsai.Expert.Var.set Keepers_var.var response
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

let start_polling () : unit =
  let _id : Brr.G.timer_id = Brr.G.set_interval ~ms:3000 run in
  ()
;;
