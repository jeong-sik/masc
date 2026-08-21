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

(* Both actor fields are resolved to a canonical Keeper name before they are
   compared, because they are recorded in different vocabularies:
   [created_by] holds a canonical Keeper name ("keeper-a", "keeper-b") while
   [cancelled_by] holds an agent name ("keeper-keeper-a-agent"). Comparing the raw
   strings reads a self-cancellation as a cross-Keeper one and wakes a Keeper
   about a decision it just made itself; resolving only by agent name finds no
   author at all.

   The two fields therefore get two resolvers rather than one that guesses.
   Nothing forbids a Keeper's agent name from colliding with another Keeper's
   lane name — [Keeper_meta_store] only requires it to be nonempty — so a
   single order is wrong for one of the fields whenever such a pair exists.
   Trying lane names first for [cancelled_by] would resolve lane [beta]'s
   agent name "alpha" to lane [alpha], and if [alpha] authored the Task the
   cross-Keeper wake would be dropped as a self-cancellation. Each resolver
   below starts from the vocabulary its field is written in, and falls back to
   the other only when the first finds nothing.

   Every lookup is scoped to [config.base_path]. A Keeper of the same name in
   another workspace is not a lane here: enqueueing to it would write a
   stimulus under this workspace's path that its own Keeper never reads, and
   report delivery for a wake nobody receives. *)
let names_a_keeper_lane ~config name =
  let base_path = config.Workspace.base_path in
  Option.is_some (Keeper_registry_lookup.find_by_name_in_base_path ~base_path name)
  || List.exists (String.equal name) (Keeper_meta_store.persisted_keeper_names config)
;;

let keeper_of_agent_binding ~config ~actor =
  match Keeper_identity_binding.resolve ~config ~agent_name:actor with
  | Keeper_identity_binding.Not_found -> Ok None
  | Keeper_identity_binding.Unique keeper_name -> Ok (Some keeper_name)
  | Keeper_identity_binding.Ambiguous keeper_names ->
    Error
      (Printf.sprintf
         "multiple registered or persisted Keepers share agent_name=%s: %s"
         actor
         (String.concat "," keeper_names))
  | Keeper_identity_binding.Lookup_failed detail -> Error detail
;;

(* [created_by] is written as a canonical Keeper name. *)
let keeper_of_author ~config ~author =
  if names_a_keeper_lane ~config author
  then Ok (Some author)
  else keeper_of_agent_binding ~config ~actor:author
;;

(* [cancelled_by] is written as an agent name — [workspace_task_lifecycle]
   stores the acting [agent_name] verbatim — so the agent binding answers it
   completely. There is deliberately no lane-name fallback: no caller writes a
   lane name here, and accepting one resolved a non-Keeper actor whose id
   happens to match a lane (an operator called "keeper-a" against Keeper lane
   "keeper-a") to that Keeper, which then read as a self-cancellation and
   swallowed a wake the author was owed. *)
let keeper_of_canceller ~config ~agent_name =
  keeper_of_agent_binding ~config ~actor:agent_name
;;

(* The wake resolves the same "why" the committed broadcast published. A
   [masc_transition] cancel with no top-level reason but a persisted handoff
   context commits with an explanation; reading only [Cancelled.reason] here
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
             (match keeper_of_author ~config ~author with
              | Error detail -> Author_lookup_failed { author; detail }
              | Ok None -> Author_not_a_keeper { author }
              | Ok (Some author_keeper) ->
                (* An unresolvable canceller is reported, never discarded.
                   Two Keeper names that differ only by the [keeper-] prefix —
                   [alpha] and [keeper-alpha] — both canonicalise to
                   [keeper-alpha-agent], so the binding is [Ambiguous] and the
                   author may be one of the candidates. Collapsing that into
                   [None] fell through to comparing the raw agent name against
                   the author lane, which misses the match and wakes a Keeper
                   about its own cancellation. Since the self-check cannot be
                   decided, nothing is enqueued and the ambiguity is surfaced
                   for repair. *)
                match
                  keeper_of_canceller ~config ~agent_name:cancelling_agent_name
                with
                | Error detail ->
                  Canceller_lookup_failed { agent_name = cancelling_agent_name; detail }
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
