type t =
  { admitted : Keeper_event_queue_state.pending_selection list
  ; pending_at_intake : Keeper_event_queue_state.pending_selection list
  }

let empty = { admitted = []; pending_at_intake = [] }
let of_intake ~pending ~admitted = { admitted; pending_at_intake = pending }
let of_selections admitted = of_intake ~pending:admitted ~admitted
let selections batch = batch.admitted
let pending_at_intake batch = batch.pending_at_intake
let stimuli batch =
  List.map (fun (selection : Keeper_event_queue_state.pending_selection) -> selection.source)
    (selections batch)
let count batch = List.length batch.admitted
let first batch = List.nth_opt batch.admitted 0

let observed_sources_to_yojson batch =
  `List
    (List.map
       (fun (selection : Keeper_event_queue_state.pending_selection) ->
          `Assoc
            [ "stimulus_id",
              `String (Keeper_reaction_ledger.stimulus_id_of_event_queue selection.source)
            ; "source_snapshot_ref",
              `String (Keeper_event_queue_state.source_snapshot_ref selection.source)
            ; "admitted_revision", `String (Int64.to_string selection.admitted_revision)
            ; "first_admitted_at",
              (match selection.first_admitted_at with
               | None -> `Null
               | Some epoch -> `Float epoch)
            ])
       (selections batch))

let validate ~diagnostic ~standing batch =
  let checked = match batch.admitted with
    | [] -> Option.to_list diagnostic
    | _ :: _ -> selections batch
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
    (match batch.admitted with
     | [] -> Ok (batch, withdrawn)
     | _ :: _ -> Ok ({ batch with admitted = kept }, withdrawn))

type turn_input = { batch : t; reactive : bool }
let for_turn ~reactive batch = { batch; reactive }
let sources input = input.batch
let wake input =
  match input.batch.admitted, input.reactive with
  | _ :: _, _ ->
    Keeper_registry.Woken
      (List.map (fun (source : Keeper_event_queue.stimulus) -> source.payload)
         (stimuli input.batch))
  | [], true -> Keeper_registry.Woken []
  | [], false -> Keeper_registry.Proactive_tick
