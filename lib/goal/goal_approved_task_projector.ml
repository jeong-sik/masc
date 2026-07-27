(** Goal-owned projection of durable Task approval events. *)

module String_set = Set.Make (String)

type t =
  { mutable last_seq : int
  ; mutable approved_task_ids : String_set.t
  }

type error =
  | Link_read_failed of string
  | Event_read_failed of string
  | Goal_update_failed of
      { goal_id : string
      ; detail : string
      }
  | Goal_event_failed of
      { goal_id : string
      ; detail : string
      }

type report =
  { eligible_goal_count : int
  ; replayed_event_count : int
  ; approved_task_count : int
  ; completed_goal_ids : string list
  ; last_seq : int
  }

type metric =
  | Verifier_approved_done_tasks of { target : int }

let create () =
  { last_seq = 0; approved_task_ids = String_set.empty }
;;

let last_seq (state : t) = state.last_seq

let error_to_string = function
  | Link_read_failed detail ->
      "goal approved-task projector link read failed: " ^ detail
  | Event_read_failed detail ->
      "goal approved-task projector event replay failed: " ^ detail
  | Goal_update_failed { goal_id; detail } ->
      Printf.sprintf
        "goal approved-task projector update failed (goal=%s): %s"
        goal_id
        detail
  | Goal_event_failed { goal_id; detail } ->
      Printf.sprintf
        "goal approved-task projector event emit failed (goal=%s): %s"
        goal_id
        detail
;;

let metric_of_goal (goal : Goal_store.goal) =
  match goal.metric, goal.target_value with
  | Some "verifier_approved_done_tasks", Some raw_target ->
      (match int_of_string_opt (String.trim raw_target) with
       | Some target when target > 0 ->
           Some (Verifier_approved_done_tasks { target })
       | Some _ | None -> None)
  | _ -> None
;;

let eligible_goal (goal : Goal_store.goal) =
  (goal.phase = Goal_phase.Executing || goal.phase = Goal_phase.Completed)
  && Option.is_some (metric_of_goal goal)
;;

let approved_task_id (event : Activity_graph.event) =
  match Event_kind.Task.of_string event.kind with
  | Some Event_kind.Task.Approved ->
      (match Json_util.get_string event.payload "task_id", event.subject with
       | Some task_id, Some subject
         when String.trim task_id <> ""
              && String.equal subject.kind "task"
              && String.equal subject.id task_id ->
           Some task_id
       | _ ->
           Log.Misc.warn
             "goal approved-task projector ignored malformed Approved event \
              (seq=%d)"
             event.seq;
           None)
  | Some
      ( Event_kind.Task.Created
      | Event_kind.Task.Claimed
      | Event_kind.Task.Started
      | Event_kind.Task.Released
      | Event_kind.Task.Done
      | Event_kind.Task.Cancelled
      | Event_kind.Task.Submit_for_verification
      | Event_kind.Task.Rejected
      | Event_kind.Task.Linked )
  | None -> None
;;

let linked_task_ids links goal_id =
  match List.assoc_opt goal_id links with
  | Some task_ids -> task_ids
  | None -> []
;;

let target_satisfied ~approved_task_ids ~links (goal : Goal_store.goal) =
  match metric_of_goal goal with
  | None -> false
  | Some (Verifier_approved_done_tasks { target }) ->
      let linked_task_ids =
        linked_task_ids links goal.id
        |> String_set.of_list
      in
      let approved_count =
        String_set.inter linked_task_ids approved_task_ids
        |> String_set.cardinal
      in
      approved_count >= target
;;

let projector_actor = "system/goal-approved-task-projector"

let ensure_completed_goal_event config (goal : Goal_store.goal) =
  try
    ignore
      (Goal_event.ensure_phase
         config
         ~goal_id:goal.id
         ~phase:Goal_phase.Completed
         ~actor:projector_actor
         ~goal_updated_at:goal.updated_at);
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Error
        (Goal_event_failed
           { goal_id = goal.id; detail = Printexc.to_string exn })
;;

let replay_events (state : t) config =
  try
    let events =
      Activity_graph.list_events
        config
        ~kinds:[ Event_kind.Task.to_string Event_kind.Task.Approved ]
        ~after_seq:state.last_seq
        ~limit:Int.max_int
        ()
    in
    let approved_task_ids, next_last_seq =
      List.fold_left
        (fun (approved, max_seq) event ->
          let approved =
            match approved_task_id event with
            | Some task_id -> String_set.add task_id approved
            | None -> approved
          in
          approved, max max_seq event.Activity_graph.seq)
        (state.approved_task_ids, state.last_seq)
        events
    in
    Ok (events, approved_task_ids, next_last_seq)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Event_read_failed (Printexc.to_string exn))
;;

let run (state : t) config =
  let eligible_goals =
    Goal_store.list_goals config ()
    |> List.filter eligible_goal
  in
  match eligible_goals with
  | [] ->
      Ok
        { eligible_goal_count = 0
        ; replayed_event_count = 0
        ; approved_task_count = String_set.cardinal state.approved_task_ids
        ; completed_goal_ids = []
        ; last_seq = state.last_seq
        }
  | _ ->
      let completed_goals, executing_goals =
        List.partition
          (fun (goal : Goal_store.goal) ->
            goal.phase = Goal_phase.Completed)
          eligible_goals
      in
      let rec ensure_existing = function
        | [] -> Ok ()
        | goal :: rest ->
            (match ensure_completed_goal_event config goal with
             | Error _ as error -> error
             | Ok () -> ensure_existing rest)
      in
      (match ensure_existing completed_goals with
       | Error _ as error -> error
       | Ok () ->
           (match executing_goals with
            | [] ->
                Ok
                  { eligible_goal_count = List.length eligible_goals
                  ; replayed_event_count = 0
                  ; approved_task_count =
                      String_set.cardinal state.approved_task_ids
                  ; completed_goal_ids = []
                  ; last_seq = state.last_seq
                  }
            | _ ->
                (match Workspace_goal_index.read_goal_task_links_r config with
                 | Error detail -> Error (Link_read_failed detail)
                 | Ok links ->
                     (match replay_events state config with
                      | Error _ as error -> error
                      | Ok (events, approved_task_ids, next_last_seq) ->
                let rec complete completed = function
                  | [] -> Ok (List.rev completed)
                  | (goal : Goal_store.goal) :: rest ->
                      if not (target_satisfied ~approved_task_ids ~links goal)
                      then complete completed rest
                      else
                        let review_at = Masc_domain.now_iso () in
                        (match
                           Goal_store.complete_goal_if_matches
                             config
                             ~goal_id:goal.id
                             ~metric:goal.metric
                             ~target_value:goal.target_value
                             ~last_review_note:
                               (Some
                                  "Completed from durable verifier-approved \
                                   Task events.")
                             ~last_review_at:(Some review_at)
                         with
                         | Error detail ->
                             Error
                               (Goal_update_failed
                                  { goal_id = goal.id; detail })
                         | Ok (Goal_store.Not_completed _) ->
                             complete completed rest
                         | Ok (Goal_store.Completed_now updated) ->
                             (match ensure_completed_goal_event config updated with
                              | Error _ as error -> error
                              | Ok () ->
                                  complete (updated.id :: completed) rest))
                in
                (match complete [] executing_goals with
                 | Error _ as error -> error
                 | Ok completed_goal_ids ->
                     state.approved_task_ids <- approved_task_ids;
                     state.last_seq <- next_last_seq;
                     Ok
                       { eligible_goal_count = List.length eligible_goals
                       ; replayed_event_count = List.length events
                       ; approved_task_count =
                           String_set.cardinal approved_task_ids
                       ; completed_goal_ids
                       ; last_seq = next_last_seq
                       }))))
       )
;;
