type t =
  | Empty
  | Selected of Keeper_event_queue_state.pending_selection *
      Keeper_event_queue_state.pending_selection list

let empty = Empty
let of_selections = function [] -> Empty | first :: rest -> Selected (first, rest)
let selections = function Empty -> [] | Selected (first, rest) -> first :: rest
let stimuli batch =
  List.map (fun (selection : Keeper_event_queue_state.pending_selection) -> selection.source)
    (selections batch)
let count = function Empty -> 0 | Selected (_, rest) -> 1 + List.length rest
let first = function Empty -> None | Selected (first, _) -> Some first

let validate ~diagnostic ~standing batch =
  let checked = match batch with
    | Empty -> Option.to_list diagnostic
    | Selected _ -> selections batch
  in
  let rec settle kept withdrawn = function
    | [] -> Ok (List.rev kept, List.rev withdrawn)
    | selection :: rest ->
      (match standing selection with
       | Error _ as error -> error
       | Ok Keeper_event_queue_state.Admitted_selection_pending ->
         settle (selection :: kept) withdrawn rest
       | Ok Keeper_event_queue_state.Admitted_selection_withdrawn ->
         settle kept (selection :: withdrawn) rest)
  in
  match settle [] [] checked with
  | Error _ as error -> error
  | Ok (kept, withdrawn) ->
    (match batch with
     | Empty -> Ok (Empty, withdrawn)
     | Selected _ -> Ok (of_selections kept, withdrawn))

type turn_input = { batch : t; reactive : bool }
let for_turn ~reactive batch = { batch; reactive }
let sources input = input.batch
let wake input =
  match input.batch, input.reactive with
  | Selected _, _ ->
    Keeper_registry.Woken
      (List.map (fun (source : Keeper_event_queue.stimulus) -> source.payload)
         (stimuli input.batch))
  | Empty, true -> Keeper_registry.Woken []
  | Empty, false -> Keeper_registry.Proactive_tick
