module Chat = Masc_tui_keeper_chat_projection

type intent =
  | Next
  | Steer_after_interrupt

type item =
  { request : Chat.request
  ; submitted_at : float
  ; intent : intent
  }

type t = item list (* dispatch order *)

let empty = []
let is_empty = function [] -> true | _ :: _ -> false
let length = List.length
let waiting queue = queue
let cap = 32

let item_keeper item = item.request.Chat.keeper_name

let waiting_for_keeper queue ~keeper_name =
  List.filter (fun item -> String.equal (item_keeper item) keeper_name) queue
;;

let length_for_keeper queue ~keeper_name =
  List.length (waiting_for_keeper queue ~keeper_name)
;;

let cap_error () =
  Error
    (Printf.sprintf
       "%d messages are already waiting for current turns; this one was not \
        queued and is still in the composer"
       cap)
;;

let push queue ~submitted_at request =
  if List.length queue >= cap
  then cap_error ()
  else (
    let item = { request; submitted_at; intent = Next } in
    let queue = queue @ [ item ] in
    Ok (queue, length_for_keeper queue ~keeper_name:request.Chat.keeper_name))
;;

let push_steer queue ~submitted_at request =
  let keeper_name = request.Chat.keeper_name in
  if List.length queue >= cap
  then cap_error ()
  else if
    List.exists
      (fun item ->
        String.equal (item_keeper item) keeper_name
        && item.intent = Steer_after_interrupt)
      queue
  then
    Error (Printf.sprintf "a steer is already waiting for Keeper %s" keeper_name)
  else
    let steer = { request; submitted_at; intent = Steer_after_interrupt } in
    let rec insert reversed = function
      | [] -> List.rev (steer :: reversed)
      | item :: rest when String.equal (item_keeper item) keeper_name ->
          List.rev_append reversed (steer :: item :: rest)
      | item :: rest -> insert (item :: reversed) rest
    in
    let queue = insert [] queue in
    Ok (queue, length_for_keeper queue ~keeper_name)
;;

let take_first_sendable queue ~sendable =
  let rec walk skipped = function
    | [] -> None
    | item :: rest when sendable (item_keeper item) ->
      Some (item, List.rev_append skipped rest)
    | item :: rest -> walk (item :: skipped) rest
  in
  walk [] queue
;;

let take_newest queue =
  match List.rev queue with
  | [] -> None
  | newest :: reversed_rest -> Some (newest, List.rev reversed_rest)
;;

let take_newest_for_keeper queue ~keeper_name =
  let rec take skipped = function
    | [] -> None
    | item :: older when String.equal (item_keeper item) keeper_name ->
        Some (item, List.rev_append older skipped)
    | item :: older -> take (item :: skipped) older
  in
  take [] (List.rev queue)
;;

let drop_for_keeper queue ~keeper_name =
  List.filter
    (fun item -> not (String.equal (item_keeper item) keeper_name))
    queue
;;

let take queue ~request_id =
  let rec walk skipped = function
    | [] -> None
    | item :: rest
      when String.equal item.request.Chat.request_id request_id ->
      Some (item, List.rev_append skipped rest)
    | item :: rest -> walk (item :: skipped) rest
  in
  walk [] queue
;;

let holds queue ~request_id =
  List.exists
    (fun item -> String.equal item.request.Chat.request_id request_id)
    queue
;;
