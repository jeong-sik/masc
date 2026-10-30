module Chat = Masc_tui_keeper_chat_projection

type intent =
  | Next
  | Next_without_auto_priority
  | Run_next of { automatic : bool }
  | Steer_after_interrupt
  | Steer_without_priority

type source =
  | Request_message
  | Staged_fragments of string list

type item =
  { request : Chat.request
  ; source : source
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

let source_text item =
  match item.source with
  | Request_message -> item.request.Chat.message
  | Staged_fragments reversed -> String.concat "\n" (List.rev reversed)
;;

let source_for_edit item ~message =
  if String.equal item.request.Chat.message message then item.source else Request_message
;;

let source_for_join item ~message =
  match item.source with
  | Request_message -> Request_message
  | Staged_fragments reversed -> Staged_fragments (message :: reversed)
;;

let source_for_staging item ~message =
  match item.source with
  | Request_message when not (String.equal item.request.Chat.message message) ->
      Staged_fragments [item.request.Chat.message]
  | Request_message | Staged_fragments _ -> item.source
;;

let item_keeper item = item.request.Chat.keeper_name

(* A steer can occupy an earlier local slot than its submission. Once a
   control supersedes that priority, restore this Keeper's submission order
   without moving another Keeper's slots. *)
let order_keeper_by_submission queue ~keeper_name =
  let belongs item = String.equal (item_keeper item) keeper_name in
  let ordered = List.filter belongs queue.items
    |> List.stable_sort (fun left right -> Int.compare left.submission_seq right.submission_seq) in
  let rec replace ordered = function
    | [] -> []
    | item :: rest when belongs item ->
        (match ordered with
         | next :: remaining -> next :: replace remaining rest
         | [] -> item :: replace [] rest)
    | item :: rest -> item :: replace ordered rest in
  {queue with items=replace ordered queue.items}
;;

let restore_unsent queue item =
  if List.exists (fun held ->
      String.equal held.request.Chat.request_id item.request.Chat.request_id) queue.items
  then queue
  else
    let restored =
      { items = item :: queue.items
      ; next_submission_seq = max queue.next_submission_seq (item.submission_seq + 1)
      } in
    match item.intent with
    | Next_without_auto_priority | Steer_without_priority ->
        order_keeper_by_submission restored ~keeper_name:(item_keeper item)
    | Next | Run_next _ | Steer_after_interrupt -> restored
;;

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
      ; source = Request_message
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
        && (item.intent = Steer_after_interrupt || item.intent = Steer_without_priority))
      queue.items
  then
    Error (Printf.sprintf "a steer is already waiting for Keeper %s" keeper_name)
  else
    let steer =
      { request
      ; source = Request_message
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

(* The one answer to "may the operator reorder this item locally". A steer and a
   run-next item hold their place ahead of the line; every other intent follows
   the line. *)
let local_order_editable item = match item.intent with
  | Next | Next_without_auto_priority | Steer_without_priority -> true
  | Run_next _ | Steer_after_interrupt -> false
;;

let move queue ~keeper_name ~request_id position =
  match find queue ~request_id with
  | None -> Error "Local queue changed; refresh and select again"
  | Some item when not (String.equal (item_keeper item) keeper_name) ->
    Error "That message belongs to another Keeper"
  | Some item when not (local_order_editable item) ->
    Error "That message keeps its place ahead of ordinary messages"
  | Some item ->
    let same_keeper = waiting_for_keeper queue ~keeper_name in
    let others = List.filter (fun current ->
      not (String.equal current.request.Chat.request_id request_id)) same_keeper in
    let reordered = match position with
      | End -> others @ [item]
      | Front ->
        let steers, ordinary = List.partition (fun current ->
          not (local_order_editable current)) others in
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
    Result.map (fun items -> {queue with items}) (rebuild reordered queue.items)
;;

let move_to_end queue ~keeper_name ~request_id =
  move queue ~keeper_name ~request_id End
;;

let move_to_front queue ~keeper_name ~request_id =
  move queue ~keeper_name ~request_id Front
;;

let replace_request ?(source = Request_message) queue ~request_id request =
  if not (String.equal request.Chat.request_id request_id)
  then Error "queue replacement must preserve request_id"
  else
    let rec replace reversed = function
      | [] -> Error "queued request is no longer waiting"
      | item :: rest
        when String.equal item.request.Chat.request_id request_id ->
          Ok { queue with items = List.rev_append reversed ({ item with request; source } :: rest) }
      | item :: rest -> replace (item :: reversed) rest
    in
    replace [] queue.items
;;

(* An editor owns the payload it recalled, not just an ID that another local
   action may have reused or changed. Preserve later priority changes on the
   queue item while refusing to overwrite a different request payload. *)
let replace_recalled_request ?source queue ~original request =
  let request_id = original.request.Chat.request_id in
  match find queue ~request_id with
  | None -> Error "queued request is no longer waiting"
  | Some current when current.request <> original.request
                      || current.source <> original.source ->
      Error "queued request changed while it was being edited"
  | Some _ -> replace_request ?source queue ~request_id request
;;

(* Priority remains on the unsent item, so editing, cancellation, suspension,
   and a preflight refusal cannot leave a separate pending request behind. *)
let mark_run_next queue ~request_id =
  let rec replace reversed = function
    | [] -> Error "queued request is no longer waiting"
    | item :: rest when String.equal item.request.Chat.request_id request_id ->
        let intent = match item.intent with
          | Next | Next_without_auto_priority | Run_next _ -> Run_next {automatic=false}
          | Steer_after_interrupt | Steer_without_priority -> Steer_after_interrupt in
        Ok {queue with items=List.rev_append reversed ({item with intent} :: rest)}
    | item :: rest -> replace (item :: reversed) rest in
  replace [] queue.items
;;

(* A real stop or resume supersedes queued run-next priority as well as the
   sidecar for already submitted requests. Steer remains its own intent. *)
let clear_run_next_for_keeper queue ~keeper_name =
  let superseded item =
    String.equal (item_keeper item) keeper_name
    && match item.intent with
       | Run_next _ | Steer_after_interrupt -> true
       | Next | Next_without_auto_priority | Steer_without_priority -> false in
  if not (List.exists superseded queue.items) then queue
  else
    let items = List.map (fun item ->
      if not (superseded item) then item
      else match item.intent with
        | Run_next _ -> {item with intent=Next_without_auto_priority}
        | Steer_after_interrupt -> {item with intent=Steer_without_priority}
        | Next | Next_without_auto_priority | Steer_without_priority -> item) queue.items in
    order_keeper_by_submission {queue with items} ~keeper_name
;;

let prepare_for_admission ~automatic item =
  match item.intent with
  | Next when automatic -> {item with intent=Run_next {automatic=true}}
  | Next | Next_without_auto_priority | Run_next _ | Steer_after_interrupt
  | Steer_without_priority -> item
;;

(* A new message joins the newest submitted ordinary item. It joins nothing
   when that item holds run-next priority, or when a steer or a run-next item
   waits behind it: joining would send the new input ahead of that priority.
   A steer ahead of it does not matter. *)
let join_target queue ~keeper_name =
  let waiting = waiting_for_keeper queue ~keeper_name in
  let is_steer item = match item.intent with
    | Steer_after_interrupt | Steer_without_priority -> true
    | Next | Next_without_auto_priority | Run_next _ -> false in
  let holds_priority item = match item.intent with
    | Steer_after_interrupt | Steer_without_priority | Run_next _ -> true
    | Next | Next_without_auto_priority -> false in
  let newest = List.fold_left (fun newest item ->
      if is_steer item then newest
      else match newest with
        | Some current when item.submission_seq <= current.submission_seq -> newest
        | Some _ | None -> Some item) None waiting in
  let rec priority_behind item = function
    | [] -> false
    | current :: rest when String.equal current.request.Chat.request_id item.request.Chat.request_id ->
        List.exists holds_priority rest
    | _ :: rest -> priority_behind item rest in
  match newest with
  | None -> None
  | Some {intent = Run_next _; _} -> None
  | Some ({intent = (Next | Next_without_auto_priority); _} as item) ->
      if priority_behind item waiting then None else Some item
  | Some {intent = (Steer_after_interrupt | Steer_without_priority); _} -> None
;;
