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

type t = { items : item list; next_submission_seq : int }

let empty = { items = []; next_submission_seq = 0 }
let is_empty queue = queue.items = []
let length queue = List.length queue.items
let waiting queue = queue.items
let cap = 32

let restore_unsent queue item =
  if List.exists (fun held ->
      String.equal held.request.Chat.request_id item.request.Chat.request_id) queue.items
  then queue
  else
    { items = item :: queue.items
    ; next_submission_seq = max queue.next_submission_seq (item.submission_seq + 1)
    }
;;

let item_keeper item = item.request.Chat.keeper_name

let waiting_for_keeper queue ~keeper_name =
  List.filter (fun item -> String.equal (item_keeper item) keeper_name) queue.items
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
  if length queue >= cap
  then cap_error ()
  else (
    let item =
      { request
      ; submitted_at
      ; submission_seq = queue.next_submission_seq
      ; intent = Next
      ; causal_parent_request_id = None
      }
    in
    let queue = { items = queue.items @ [ item ]; next_submission_seq = queue.next_submission_seq + 1 } in
    Ok (queue, length_for_keeper queue ~keeper_name:request.Chat.keeper_name))
;;

let push_steer queue ~submitted_at ~causal_parent_request_id request =
  let keeper_name = request.Chat.keeper_name in
  if length queue >= cap
  then cap_error ()
  else if
    List.exists
      (fun item ->
        String.equal (item_keeper item) keeper_name
        && item.intent = Steer_after_interrupt)
      queue.items
  then
    Error (Printf.sprintf "a steer is already waiting for Keeper %s" keeper_name)
  else
    let steer =
      { request
      ; submitted_at
      ; submission_seq = queue.next_submission_seq
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
    let queue = { items = insert [] queue.items; next_submission_seq = queue.next_submission_seq + 1 } in
    Ok (queue, length_for_keeper queue ~keeper_name)
;;

let take_first_sendable queue ~sendable =
  let rec walk skipped = function
    | [] -> None
    | item :: rest when sendable (item_keeper item) ->
      Some (item, { queue with items = List.rev_append skipped rest })
    | item :: rest -> walk (item :: skipped) rest
  in
  walk [] queue.items
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
      None queue.items
  in
  let rec remove request_id skipped = function
    | [] -> None
    | item :: rest when String.equal item.request.Chat.request_id request_id ->
        Some (item, { queue with items = List.rev_append skipped rest })
    | item :: rest -> remove request_id (item :: skipped) rest
  in
  Option.bind newest (fun item -> remove item.request.request_id [] queue.items)
;;

let take queue ~request_id =
  let rec walk skipped = function
    | [] -> None
    | item :: rest
      when String.equal item.request.Chat.request_id request_id ->
      Some (item, { queue with items = List.rev_append skipped rest })
    | item :: rest -> walk (item :: skipped) rest
  in
  walk [] queue.items
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
      None queue.items
  in
  Option.bind newest (fun item -> take queue ~request_id:item.request.request_id)
;;

let holds queue ~request_id =
  List.exists
    (fun item -> String.equal item.request.Chat.request_id request_id)
    queue.items
;;

let find queue ~request_id =
  List.find_opt
    (fun item -> String.equal item.request.Chat.request_id request_id)
    queue.items
;;

type queue_position = Front | End

let move queue ~keeper_name ~request_id position =
  match find queue ~request_id with
  | None -> Error "Local queue changed; refresh and select again"
  | Some item when not (String.equal (item_keeper item) keeper_name) ->
    Error "That message belongs to another Keeper"
  | Some item ->
    (match item.intent with
    | Steer_after_interrupt -> Error "A steer retains its place ahead of ordinary messages"
    | Next ->
    let same_keeper = waiting_for_keeper queue ~keeper_name in
    let others = List.filter (fun current ->
      not (String.equal current.request.Chat.request_id request_id)) same_keeper in
    let reordered = match position with
      | End -> others @ [item]
      | Front ->
        let steers, ordinary = List.partition (fun current ->
          match current.intent with Steer_after_interrupt -> true | Next -> false) others in
        steers @ (item :: ordinary) in
    let rec rebuild pending = function
      | [] ->
        (match pending with [] -> Ok [] | _ :: _ -> Error "Local queue changed")
      | current :: rest when String.equal (item_keeper current) keeper_name ->
        (match pending with
         | [] -> Error "Local queue changed"
         | replacement :: remaining ->
           Result.map (fun tail -> replacement :: tail) (rebuild remaining rest))
      | current :: rest -> Result.map (fun tail -> current :: tail) (rebuild pending rest)
    in
    Result.map (fun items -> {queue with items}) (rebuild reordered queue.items))
;;

let move_to_end queue ~keeper_name ~request_id =
  move queue ~keeper_name ~request_id End
;;

let move_to_front queue ~keeper_name ~request_id =
  move queue ~keeper_name ~request_id Front
;;

let replace_request queue ~request_id request =
  if not (String.equal request.Chat.request_id request_id)
  then Error "queue replacement must preserve request_id"
  else
    let rec replace reversed = function
      | [] -> Error "queued request is no longer waiting"
      | item :: rest
        when String.equal item.request.Chat.request_id request_id ->
          Ok { queue with items = List.rev_append reversed ({ item with request } :: rest) }
      | item :: rest -> replace (item :: reversed) rest
    in
    replace [] queue.items
;;

let join_target queue ~keeper_name =
  waiting_for_keeper queue ~keeper_name
  |> List.fold_left (fun newest item ->
       match item.intent, newest with
       | Steer_after_interrupt, _ -> newest
       | Next, None -> Some item
       | Next, Some current when item.submission_seq > current.submission_seq -> Some item
       | Next, Some _ -> newest) None
;;
