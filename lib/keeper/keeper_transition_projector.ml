type projection_failure =
  | Queue_read_failed of { detail : string }
  | Reaction_append_failed of
      { transition_id : string
      ; stimulus_post_id : string
      ; detail : string
      }
  | Projection_mark_failed of
      { transition_id : string
      ; detail : string
      }
  | Multiple_unprojected_transitions of { count : int }

type projection_report =
  { projected_transition_count : int
  ; projected_stimulus_count : int
  }

let projection_failure_to_string = function
  | Queue_read_failed { detail }
  | Reaction_append_failed { detail; _ }
  | Projection_mark_failed { detail; _ } ->
    detail
  | Multiple_unprojected_transitions _ ->
    "event queue state has multiple unprojected transitions"
;;

let reaction_kind_of_settlement = function
  | Keeper_registry_event_queue.Ack -> Keeper_reaction_ledger.Event_queue_ack
  | Keeper_registry_event_queue.Requeue _ ->
    Keeper_reaction_ledger.Event_queue_requeued
  | Keeper_registry_event_queue.Escalate _ ->
    Keeper_reaction_ledger.Event_queue_escalated
;;

let project_transition_outbox ~base_path ~keeper_name =
  let rec project_stimuli ~reaction_kind ~receipt ~projected_count = function
    | [] -> Ok projected_count
    | stimulus :: rest ->
      (match
         Keeper_reaction_ledger.record_event_queue_transition_reaction_result
           ~base_path
           ~keeper_name
           ~reaction_kind
           ~receipt
           stimulus
       with
       | Error detail ->
         Error
           (Reaction_append_failed
              { transition_id = receipt.transition_id
              ; stimulus_post_id = stimulus.Keeper_event_queue.post_id
              ; detail
              })
       | Ok () ->
         project_stimuli
           ~reaction_kind
           ~receipt
           ~projected_count:(projected_count + 1)
           rest)
  in
  match Keeper_registry_event_queue.transition_outbox_result ~base_path keeper_name with
  | Error detail -> Error (Queue_read_failed { detail })
  | Ok [] ->
    Ok { projected_transition_count = 0; projected_stimulus_count = 0 }
  | Ok [ (entry : Keeper_registry_event_queue.outbox_entry) ] ->
    let receipt = entry.receipt in
    let reaction_kind = reaction_kind_of_settlement receipt.settlement in
    (match
       project_stimuli
         ~reaction_kind
         ~receipt
         ~projected_count:0
         entry.stimuli
     with
     | Error _ as error -> error
     | Ok projected_stimulus_count ->
       (match
          Keeper_registry_event_queue.mark_transition_projected_result
            ~base_path
            keeper_name
            ~transition_id:receipt.transition_id
        with
        | Error detail ->
          Error
            (Projection_mark_failed
               { transition_id = receipt.transition_id; detail })
        | Ok () ->
          Ok { projected_transition_count = 1; projected_stimulus_count }))
  | Ok entries ->
    Error (Multiple_unprojected_transitions { count = List.length entries })
;;
