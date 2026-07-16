type t =
  { base_path : string
  ; keeper_name : string
  ; project : unit -> (int, string) result
  ; dispatch :
      (unit -> (int, string) result) ->
      (int, string) result
  ; wake_pending : bool Atomic.t
  ; stop_requested : bool Atomic.t
  ; wake_condition : Eio.Condition.t
  }

let reaction_kind_of_settlement = function
  | Keeper_registry_event_queue.Ack -> Keeper_reaction_ledger.Event_queue_ack
  | Keeper_registry_event_queue.Requeue _ ->
    Keeper_reaction_ledger.Event_queue_requeued
  | Keeper_registry_event_queue.Escalate _ ->
    Keeper_reaction_ledger.Event_queue_escalated
;;

let project_pending ~base_path ~keeper_name =
  let rec project_entries count = function
    | [] -> Ok count
    | (entry : Keeper_registry_event_queue.outbox_entry) :: rest ->
      let receipt = entry.receipt in
      let reaction_kind = reaction_kind_of_settlement receipt.settlement in
      (match
         Keeper_reaction_ledger.record_event_queue_transition_reaction_result
           ~base_path
           ~keeper_name
           ~reaction_kind
           ~receipt
           entry.stimulus
       with
       | Error _ as error -> error
       | Ok () ->
         (match
            Keeper_registry_event_queue.mark_transition_projected_result
              ~base_path
              keeper_name
              ~transition_id:receipt.transition_id
          with
          | Error _ as error -> error
          | Ok () -> project_entries (count + 1) rest))
  in
  match Keeper_registry_event_queue.transition_outbox_result ~base_path keeper_name with
  | Error _ as error -> error
  | Ok entries -> project_entries 0 entries
;;

let create_with_dispatch ~base_path ~keeper_name ~project ~dispatch =
  { base_path
  ; keeper_name
  ; project
  ; dispatch
  ; wake_pending = Atomic.make true
  ; stop_requested = Atomic.make false
  ; wake_condition = Eio.Condition.create ()
  }
;;

let create_with_project ~base_path ~keeper_name ~project =
  create_with_dispatch
    ~base_path
    ~keeper_name
    ~project
    ~dispatch:(fun project -> project ())
;;

let create ~base_path ~keeper_name =
  create_with_dispatch
    ~base_path
    ~keeper_name
    ~project:(fun () -> project_pending ~base_path ~keeper_name)
    ~dispatch:(fun project ->
      match Executor_pool_ref.get () with
      | None -> Error "server executor pool is unavailable"
      | Some pool ->
        Eio.Executor_pool.submit_exn pool ~weight:1.0 (fun () ->
          Eio.Switch.run (fun _sw -> project ())))
;;

let notify t =
  Atomic.set t.wake_pending true;
  Eio.Condition.broadcast t.wake_condition
;;

let stop t =
  Atomic.set t.stop_requested true;
  Eio.Condition.broadcast t.wake_condition
;;

type command =
  | Project
  | Stop

let await_command t =
  Eio.Condition.loop_no_mutex t.wake_condition (fun () ->
    if Atomic.get t.stop_requested
    then Some Stop
    else if Atomic.exchange t.wake_pending false
    then Some Project
    else None)
;;

let project_once t =
  let result =
    try
      t.dispatch (fun () ->
        try t.project () with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          Error
            (Printf.sprintf
               "unexpected projector exception: %s"
               (Printexc.to_string exn)))
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Error
        (Printf.sprintf
           "projector dispatch failed: %s"
           (Printexc.to_string exn))
  in
  match result with
  | Ok _ -> ()
  | Error detail ->
    Log.Keeper.error
      "reaction ledger projector failed keeper=%s base_path=%s: %s"
      t.keeper_name
      t.base_path
      detail
;;

let run t =
  let rec loop () =
    match await_command t with
    | Stop -> ()
    | Project ->
      project_once t;
      loop ()
  in
  loop ()
;;

module For_testing = struct
  let create_with_project = create_with_project
end
