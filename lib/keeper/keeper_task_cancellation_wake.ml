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
  | Enqueue_failed _ -> "enqueue_failed"
;;

(* Author and canceller are compared through the Keeper identity binding rather
   than by string equality: the backlog records an author under its canonical
   Keeper name ("sangsu") while the canceller arrives as an agent name
   ("keeper-sangsu-agent"), so a raw comparison reads a self-cancellation as a
   cross-Keeper one and wakes a Keeper about its own decision. *)
let keeper_of_agent_name ~config ~agent_name =
  match Keeper_identity_binding.resolve ~config ~agent_name with
  | Keeper_identity_binding.Not_found -> Ok None
  | Keeper_identity_binding.Unique keeper_name -> Ok (Some keeper_name)
  | Keeper_identity_binding.Ambiguous keeper_names ->
    Error
      (Printf.sprintf
         "multiple registered or persisted Keepers share agent_name=%s: %s"
         agent_name
         (String.concat "," keeper_names))
  | Keeper_identity_binding.Lookup_failed detail -> Error detail
;;

let cancellation_of_task (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Cancelled { cancelled_by; reason; _ } -> Some (cancelled_by, reason)
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

let notify_author ~config ~cancelling_agent_name ~task_id =
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
             (match keeper_of_agent_name ~config ~agent_name:author with
              | Error detail -> Author_lookup_failed { author; detail }
              | Ok None -> Author_not_a_keeper { author }
              | Ok (Some author_keeper) ->
                let canceller_keeper =
                  match
                    keeper_of_agent_name ~config ~agent_name:cancelling_agent_name
                  with
                  | Ok (Some keeper_name) -> Some keeper_name
                  | Ok None | Error _ -> None
                in
                let is_self =
                  match canceller_keeper with
                  | Some canceller -> String.equal canceller author_keeper
                  | None -> String.equal cancelling_agent_name author
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
