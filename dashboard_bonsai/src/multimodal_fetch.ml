(** Single-shot fetch of [/api/v1/multimodal/list] + 5 s polling.

    Mirrors [Logs_fetch] / [Keepers_fetch] pattern. Failed fetches leave the
    previously-stored response in [Multimodal_var] but stamp it stale so old
    artifact data is not presented as current. *)

open! Core
open Brr_io

let endpoint = "/api/v1/multimodal/list"

let consecutive_failures = ref 0
let last_response = ref Multimodal_types.empty_response

let store_success (response : Multimodal_types.response) : unit =
  consecutive_failures := 0;
  let response =
    { response with fetch_status = Multimodal_types.Fetch_fresh }
  in
  last_response := response;
  Bonsai.Expert.Var.set Multimodal_var.var response
;;

let store_failure (reason : string) : unit =
  consecutive_failures := !consecutive_failures + 1;
  let response =
    { !last_response with
      fetch_status =
        Multimodal_types.Fetch_stale
          { reason; consecutive_failures = !consecutive_failures }
    }
  in
  Bonsai.Expert.Var.set Multimodal_var.var response
;;

let parse_and_store (text : Jstr.t) : unit =
  match Yojson.Safe.from_string (Jstr.to_string text) with
  | json ->
    let response = Multimodal_types.response_of_yojson json in
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
