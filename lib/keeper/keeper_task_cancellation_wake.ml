(** See [keeper_task_cancellation_wake.mli] for the contract. *)

type outcome =
  | Delivered of { keeper_name : string }
  | Already_present of { keeper_name : string }
  | Not_cancelled
  | Self_cancelled
  | No_author
  | Author_not_a_keeper of { author : string }
  | Backlog_read_failed of { detail : string }
  | Author_lookup_failed of
      { author : string
      ; detail : string
      }
  | Canceller_lookup_failed of
      { agent_name : string
      ; detail : string
      }
  | Enqueue_failed of
      { keeper_name : string
      ; detail : string
      }

let outcome_label = function
  | Delivered _ -> "delivered"
  | Already_present _ -> "already_present"
  | Not_cancelled -> "not_cancelled"
  | Self_cancelled -> "self_cancelled"
  | No_author -> "no_author"
  | Author_not_a_keeper _ -> "author_not_a_keeper"
  | Backlog_read_failed _ -> "backlog_read_failed"
  | Author_lookup_failed _ -> "author_lookup_failed"
  | Canceller_lookup_failed _ -> "canceller_lookup_failed"
  | Enqueue_failed _ -> "enqueue_failed"
;;

(* Only a typed agent actor is eligible for the Keeper self-cancellation check.
   Its name and [created_by] use the canonical Keeper identity (RFC-0393).
   An operator or system identity may have the same spelling without being that
   Keeper. Every lookup is scoped to [config.base_path]. A Keeper of the same name in
   another workspace is not a lane here: enqueueing to it would write a
   stimulus under this workspace's path that its own Keeper never reads, and
   report delivery for a wake nobody receives. *)
let names_a_keeper_lane ~config name =
  let base_path = config.Workspace.base_path in
  Option.is_some (Keeper_registry_lookup.find_by_name_in_base_path ~base_path name)
  || List.exists (String.equal name) (Keeper_meta_store.persisted_keeper_names config)
;;

let keeper_of_agent_binding ~config ~actor =
  if names_a_keeper_lane ~config actor then Ok (Some actor) else Ok None
;;

(* [created_by] is written as a canonical Keeper name. *)
let keeper_of_author ~config ~author =
  if names_a_keeper_lane ~config author
  then Ok (Some author)
  else keeper_of_agent_binding ~config ~actor:author
;;

let keeper_of_canceller ~config ~(actor : Workspace_hooks.task_terminal_actor) =
  match actor with
  | Workspace_hooks.Task_terminal_agent agent_name ->
    keeper_of_agent_binding ~config ~actor:agent_name
    |> Result.map_error (fun detail -> agent_name, detail)
  | Workspace_hooks.Task_terminal_operator _
  | Workspace_hooks.Task_terminal_system _ -> Ok None
;;

(* The wake resolves the same "why" the committed broadcast published. New
   cancels always commit a stated reason ([Workspace_task_lifecycle.decide]
   refuses one without), so the persisted-handoff fallback below serves only
   rows committed before that gate; reading only [Cancelled.reason] for those
   delivered the author a row with none, losing exactly the context this wake
   exists to carry. [Masc_domain.stated_reason] is the shared rule. *)
let cancellation_of_task (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Cancelled { cancelled_by; reason; _ } ->
    Some
      ( cancelled_by
      , Masc_domain.stated_reason ~reason ~handoff_context:task.handoff_context )
  | Masc_domain.Todo
  | Masc_domain.Claimed _
  | Masc_domain.InProgress _
  | Masc_domain.AwaitingVerification _
  | Masc_domain.Done _ -> None
;;

let enqueue ~config ~keeper_name ~(cancellation : Keeper_event_queue.task_cancellation)
  =
  let stimulus : Keeper_event_queue.stimulus =
    { post_id = Keeper_event_queue.task_cancellation_post_id cancellation
    ; urgency = Keeper_event_queue.Normal
      (* Not [Immediate]: the cancellation already committed, so nothing is
         waiting on the author's response. It must arrive, not pre-empt. *)
    ; arrived_at = Time_compat.now ()
    ; payload = Keeper_event_queue.Task_cancelled cancellation
    }
  in
  match
    Keeper_registry_event_queue.enqueue_stimulus_durable_result
      ~base_path:config.Workspace.base_path
      keeper_name
      stimulus
  with
  | Keeper_registry_event_queue.Stimulus_enqueued ->
    (* The enqueue is the durable delivery; the wake only shortens the latency,
       so a registry that declines to signal is not a delivery failure. *)
    let (_ : Keeper_registry.wakeup_outcome) =
      Keeper_registry.wakeup_running
        ~intent:Keeper_registry.Reactive_signal
        ~base_path:config.Workspace.base_path
        keeper_name
    in
    Delivered { keeper_name }
  | Keeper_registry_event_queue.Stimulus_already_present ->
    Already_present { keeper_name }
  | Keeper_registry_event_queue.Stimulus_storage_error detail ->
    Enqueue_failed { keeper_name; detail }
;;

let notify_author ~config ~actor ~task_id =
  match Workspace_backlog.read_backlog_r config with
  | Error detail -> Backlog_read_failed { detail }
  | Ok backlog ->
    (match
       List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id) backlog.tasks
     with
     | None ->
       (* The commit that triggered this wrote the task, so its absence is a
          backlog disagreement, not a missing addressee. *)
       Backlog_read_failed
         { detail = Printf.sprintf "task %s absent from the committed backlog" task_id }
     | Some task ->
       (match cancellation_of_task task with
        | None -> Not_cancelled
        | Some (cancelled_by, reason) ->
          (match task.created_by with
           | None -> No_author
           | Some author ->
             (match keeper_of_author ~config ~author with
              | Error detail -> Author_lookup_failed { author; detail }
              | Ok None -> Author_not_a_keeper { author }
              | Ok (Some author_keeper) ->
                (* A failed agent lookup cannot decide self-cancellation.
                   Operator/system actors deliberately do not use that lookup. *)
                match
                  keeper_of_canceller ~config ~actor
                with
                | Error (agent_name, detail) ->
                  Canceller_lookup_failed { agent_name; detail }
                | Ok canceller_keeper ->
                  (* A canceller that resolves to no lane is not the author,
                     who resolved to one. Comparing the raw actor string
                     against [created_by] instead made any non-Keeper actor
                     sharing the author's name read as a self-cancellation. *)
                  let is_self =
                    match canceller_keeper with
                    | Some canceller -> String.equal canceller author_keeper
                    | None -> false
                  in
                  if is_self
                  then Self_cancelled
                  else
                    enqueue
                      ~config
                      ~keeper_name:author_keeper
                      ~cancellation:
                        { tc_task_id = task_id
                        ; tc_cancelled_by = cancelled_by
                        ; tc_reason = reason
                        }))))
;;
