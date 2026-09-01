module Chat = Masc_tui_keeper_chat_projection

type intent =
  | Next
  | Steer_after_interrupt

type item =
  { request : Chat.request
  ; submitted_at : float
  ; submission_seq : int
  ; intent : intent
  ; causal_parent_request_id : string option
  }

type t = item list (* dispatch order *)

let empty = []
let is_empty = function [] -> true | _ :: _ -> false
let length = List.length
let waiting queue = queue
let cap = 32

let next_submission_seq queue =
  List.fold_left (fun next item -> max next (item.submission_seq + 1)) 0 queue
;;

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
    let item =
      { request
      ; submitted_at
      ; submission_seq = next_submission_seq queue
      ; intent = Next
      ; causal_parent_request_id = None
      }
    in
    let queue = queue @ [ item ] in
    Ok (queue, length_for_keeper queue ~keeper_name:request.Chat.keeper_name))
;;

let push_steer queue ~submitted_at ~causal_parent_request_id request =
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
    let steer =
      { request
      ; submitted_at
      ; submission_seq = next_submission_seq queue
      ; intent = Steer_after_interrupt
      ; causal_parent_request_id = Some causal_parent_request_id
      }
    in
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
  let newest =
    List.fold_left
      (fun newest item ->
        match newest with
        | None -> Some item
        | Some current when item.submission_seq > current.submission_seq ->
            Some item
        | Some _ -> newest)
      None queue
  in
  let rec remove request_id skipped = function
    | [] -> None
    | item :: rest when String.equal item.request.Chat.request_id request_id ->
        Some (item, List.rev_append skipped rest)
    | item :: rest -> remove request_id (item :: skipped) rest
  in
  Option.bind newest (fun item -> remove item.request.request_id [] queue)
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

let take_newest_for_keeper queue ~keeper_name =
  let newest =
    List.fold_left
      (fun newest item ->
        if not (String.equal (item_keeper item) keeper_name)
        then newest
        else
          match newest with
          | None -> Some item
          | Some current when item.submission_seq > current.submission_seq ->
              Some item
          | Some _ -> newest)
      None queue
  in
  Option.bind newest (fun item -> take queue ~request_id:item.request.request_id)
;;

let drop_for_keeper queue ~keeper_name =
  List.filter
    (fun item -> not (String.equal (item_keeper item) keeper_name))
    queue
;;

let holds queue ~request_id =
  List.exists
    (fun item -> String.equal item.request.Chat.request_id request_id)
    queue
;;

let find queue ~request_id =
  List.find_opt
    (fun item -> String.equal item.request.Chat.request_id request_id)
    queue
;;

let replace_request queue ~request_id request =
  if not (String.equal request.Chat.request_id request_id)
  then Error "queue replacement must preserve request_id"
  else
    let rec replace reversed = function
      | [] -> Error "queued request is no longer waiting"
      | item :: rest
        when String.equal item.request.Chat.request_id request_id ->
          Ok (List.rev_append reversed ({ item with request } :: rest))
      | item :: rest -> replace (item :: reversed) rest
    in
    replace [] queue
;;
