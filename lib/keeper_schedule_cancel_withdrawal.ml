module Persistence = Keeper_event_queue_persistence
module State = Keeper_event_queue_state

open Result.Syntax

let matches schedule_id (source : Keeper_event_queue.stimulus) =
  match source.payload with
  | Schedule_due wake -> String.equal schedule_id wake.schedule_id
  | Bootstrap | Board_signal _ | Board_attention _ | Fusion_completed _
  | Connector_attention _ | Hitl_resolved _ | Ask_answered _
  | Completion_authority_rejected _ | Task_cancelled _ | Workspace_message _
  | Delegate_completed _ | Composition_completed _ | Tool_result_ready _
  | Owned_job_completed _ | Addon_operation_changed _ | Task_outcome _ -> false
;;

let discover ~base_path =
  let discovery = Persistence.discover_keeper_names_with_durable_state ~base_path in
  match discovery.read_error with
  | Some detail -> Error ("schedule cancellation discovery failed: " ^ detail)
  | None -> Ok discovery.keeper_names
;;

let inspect ~base_path ~schedule_id keeper_name =
  let* state = Persistence.load_state_result ~base_path ~keeper_name in
  let transfer_pending =
    List.exists
      (fun (entry : State.outbox_entry) ->
         match entry.receipt.transition with
         | Transfer_accepted transfer -> matches schedule_id transfer.source
         | Cancel_accepted _ | Ack_source_terminal _ -> false)
      (State.transition_outbox state)
  in
  if transfer_pending
  then Error
      (Printf.sprintf
         "schedule %s has an unfinished transfer at Keeper %s; recover the transfer before retrying cancellation"
         schedule_id keeper_name)
  else Ok state
;;

let run config (request : Schedule_domain.schedule_request)
      (cancellation : Schedule_domain.cancellation)
  =
  (* The caller holds the schedule ledger lock. Every composed transfer and
     transfer recovery holds that same lock through target projection, after
     acquiring its ordered intake fences. This callback must never acquire
     intake fences or run recovery: an unfinished transfer is a retryable
     refusal, and partial withdrawals remain durable if a later step fails. *)
  let base_path = config.Workspace.base_path in
  let schedule_id = request.schedule_id in
  let* owners = discover ~base_path in
  let* () =
    List.fold_left
      (fun result keeper_name ->
         let* () = result in
         inspect ~base_path ~schedule_id keeper_name |> Result.map (fun _ -> ()))
      (Ok ()) owners
  in
  let* () =
    List.fold_left
      (fun result keeper_name ->
         let* () = result in
         Keeper_registry_event_queue.cancel_scheduled_wakes_result
           ~base_path keeper_name ~applied_at:(Time_compat.now ())
           ~schedule_ids:[schedule_id]
           ~reason:(Printf.sprintf "schedule %s cancelled by %s: %s"
                      schedule_id cancellation.cancelled_by.id cancellation.reason)
         |> Result.map (fun _ -> ()))
      (Ok ()) owners
  in
  (* Re-discover and re-read authority after every exact transition. ACK or
     reprioritization may win the queue lock, changing the selected revision;
     an already-left result alone cannot prove the public schedule is empty. *)
  let* owners = discover ~base_path in
  List.fold_left
    (fun result keeper_name ->
       let* () = result in
       let* state = inspect ~base_path ~schedule_id keeper_name in
       if List.exists (fun (selection : State.pending_selection) ->
           matches schedule_id selection.source) (State.pending_selections state)
       then Error (Printf.sprintf "schedule %s still has pending work at Keeper %s; retry cancellation"
                     schedule_id keeper_name)
       else Ok ())
    (Ok ()) owners
;;
