(** Single-shot fetch of [/api/v1/multimodal/list] + 5 s polling.

    Mirrors [Overview_fetch] / [Logs_fetch] pattern. Failed fetches
    leave the previously-stored response in [Multimodal_var]. *)

open! Core
open Brr_io

let endpoint = "/api/v1/multimodal/list"

let parse_and_store (text : Jstr.t) : unit =
  match Yojson.Safe.from_string (Jstr.to_string text) with
  | json ->
    let response = Multimodal_types.response_of_yojson json in
    Bonsai.Expert.Var.set Multimodal_var.var response
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
  let _id : Brr.G.timer_id = Brr.G.set_interval ~ms:5000 run in
  ()
;;
