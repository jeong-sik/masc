module Chat = Masc_tui_keeper_chat_projection

type t = Chat.request list (* oldest first *)

let empty = []
let is_empty = function [] -> true | _ :: _ -> false
let length = List.length
let waiting queue = queue
let cap = 32

let push queue request =
  if List.length queue >= cap
  then
    Error
      (Printf.sprintf
         "%d messages are already waiting for the current turn; this one was \
          not queued and is still in the composer"
         cap)
  else (
    let queue = queue @ [ request ] in
    Ok (queue, List.length queue))
;;

let take_first_sendable queue ~sendable =
  let rec walk skipped = function
    | [] -> None
    | (request : Chat.request) :: rest when sendable request.keeper_name ->
      Some (request, List.rev_append skipped rest)
    | request :: rest -> walk (request :: skipped) rest
  in
  walk [] queue
;;

let take_newest queue =
  match List.rev queue with
  | [] -> None
  | newest :: reversed_rest -> Some (newest, List.rev reversed_rest)
;;

let drop_for_keeper queue ~keeper_name =
  List.filter
    (fun (request : Chat.request) ->
      not (String.equal request.keeper_name keeper_name))
    queue
;;

let take queue ~request_id =
  let rec walk skipped = function
    | [] -> None
    | (request : Chat.request) :: rest
      when String.equal request.request_id request_id ->
      Some (request, List.rev_append skipped rest)
    | request :: rest -> walk (request :: skipped) rest
  in
  walk [] queue
;;

let holds queue ~request_id =
  List.exists
    (fun (request : Chat.request) ->
      String.equal request.request_id request_id)
    queue
;;
