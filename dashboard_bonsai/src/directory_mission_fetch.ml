open! Core
open Brr_io

let endpoint = "/api/v1/dashboard/mission"

let parse_and_store (text : Jstr.t) : unit =
  match Yojson.Safe.from_string (Jstr.to_string text) with
  | json ->
    let response = Directory_mission_types.response_of_yojson json in
    Bonsai.Expert.Var.set Directory_mission_var.var response
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
