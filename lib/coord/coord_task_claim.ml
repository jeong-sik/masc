(** Coord_task_claim — claim_task, claim_task_r, release/reclaim helpers.

    Extracted from Coord_task to separate claim logic from classification,
    creation, and transitions.  All bindings are re-exported by [Coord_task]
    via [include Coord_task_claim]. *)

open Masc_domain
include Coord_utils
include Coord_state
open Coord_backlog
open Coord_identity
include Coord_broadcast
open Coord_backlog
open Coord_identity

let is_legacy_auto_cycle_do_not_reclaim_reason reason =
  let trimmed = String.trim reason in
  let prefix = "auto: " in
  let parse_suffix suffix =
    let prefix_len = String.length prefix in
    let suffix_len = String.length suffix in
    let len = String.length trimmed in
    if
      len > prefix_len + suffix_len
      && String.starts_with ~prefix trimmed
      && String.ends_with ~suffix trimmed
    then
      let raw_count = String.sub trimmed prefix_len (len - prefix_len - suffix_len) in
      match int_of_string_opt raw_count with
      | Some count -> count >= 3
      | None -> false
    else
      false
  in
  parse_suffix " releases" || parse_suffix " cancellations"
;;

let do_not_reclaim_reason_blocks_claim = function
  | Some reason when is_legacy_auto_cycle_do_not_reclaim_reason reason -> None
  | Some _ as reason -> reason
  | None -> None
;;

let clear_soft_do_not_reclaim_reason (task : Masc_domain.task) =
  match task.do_not_reclaim_reason with
  | Some reason
    when is_legacy_auto_cycle_do_not_reclaim_reason reason ->
    { task with do_not_reclaim_reason = None }
  | Some _ | None -> task
;;

let clear_stale_worktree_binding (task : Masc_domain.task) =
  match task.worktree with
  | None -> task
  | Some _ -> { task with worktree = None }
;;

(** Preempt Claimed-only tasks owned by [agent_name] back to Todo.
    InProgress/AwaitingVerification tasks are left untouched. *)
let auto_release_claimed_for_agent config ~agent_name ~exclude_task_id (backlog : Masc_domain.backlog)
    =
  let claimed_by_me =
    backlog.tasks |> List.filter_map (fun (t : task) ->
      match t.task_status with
      | Claimed { assignee; _ }
        when Coord_task_classify.same_task_actor config assignee agent_name
             && t.id <> exclude_task_id -> Some t.id
      | Todo | Claimed _ | InProgress _
      | AwaitingVerification _ | Done _ | Cancelled _ -> None)
  in
  match claimed_by_me with
  | [] -> (backlog, [])
  | ids ->
    let new_tasks = List.map (fun (t : task) ->
      if List.mem t.id ids then { t with task_status = Todo } else t) backlog.tasks in
    ({ backlog with tasks = new_tasks }, ids)

(* fire-and-forget: broadcast auto-release for operator visibility *)
let broadcast_auto_releases config ~agent_name ~claimed_task_id auto_released_ids =
  List.iter (fun released_id ->
      ignore (broadcast config ~from_agent:agent_name
        ~content:(Printf.sprintf "Auto-released %s (claimed, not started) to claim %s"
           released_id claimed_task_id));
      log_event config (`Assoc
        [ ("type", `String "task_auto_release"); ("agent", `String agent_name)
        ; ("task", `String released_id); ("reason", `String "preempted_for_claim")
        ; ("ts", `String (now_iso ())) ]))
    auto_released_ids
;;

let active_owned_task_ids_for_agent config ~agent_name (backlog : Masc_domain.backlog)
  =
  backlog.tasks
  |> List.filter_map (fun (task : Masc_domain.task) ->
         match task.task_status with
         | Claimed { assignee; _ } | InProgress { assignee; _ }
           when Coord_task_classify.same_task_actor config assignee agent_name ->
           Some task.id
         | Todo
         | Claimed _
         | InProgress _
         | AwaitingVerification _
         | Done _
         | Cancelled _ -> None)
  |> List.sort_uniq String.compare
;;

let active_ownership_conflict_message ~agent_name ~requested_task_id task_ids =
  Printf.sprintf
    "Agent %s has task(s) in progress: %s. Use keeper_task_done (task_id + result) \
     or keeper_task_force_release (task_id + reason) to finish them before claiming %s."
    agent_name
    (String.concat ", " task_ids)
    requested_task_id
;;

let active_ownership_conflict_for_claim config ~agent_name ~requested_task_id
    (backlog : Masc_domain.backlog) =
  match
    active_owned_task_ids_for_agent config ~agent_name backlog
    |> List.filter (fun task_id -> not (String.equal task_id requested_task_id))
  with
  | [] -> None
  | task_ids ->
    Some (active_ownership_conflict_message ~agent_name ~requested_task_id task_ids)
;;

(** Result-returning version of claim_task for type-safe error handling. *)
let claim_task_r config ~agent_name ~task_id ?agent_tool_names ()
  : string Masc_domain.masc_result
  =
  let open Result.Syntax in
  let* () = if not (is_initialized config) then Error (Masc_domain.System Masc_domain.System_error.NotInitialized) else Ok () in
  let* () =
    match validate_agent_name_r agent_name, validate_task_id_r task_id with
    | Error e, _ -> Error e
    | _, Error e -> Error e
    | Ok _, Ok _ -> Ok ()
  in
  (* BUG-005: Verify agent has joined before allowing claim. *)
  let actual_name = resolve_agent_name config agent_name in
  let filename = safe_filename actual_name ^ ".json" in
  let agent_path = Filename.concat (agents_dir config) filename in
  let agent_joined = path_exists config agent_path in
  let* () =
    if not agent_joined then Error (Masc_domain.Agent (Masc_domain.Agent_error.NotJoined actual_name)) else Ok ()
  in
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
    match read_backlog_r config with
    | Error msg -> Error (Masc_domain.System (Masc_domain.System_error.IoError msg))
    | Ok backlog ->
      (try
         (* Check role constraint before attempting claim *)
         let target_task = List.find_opt (fun (t : task) -> t.id = task_id) backlog.tasks in
         let* task =
           match target_task with
           | None -> Error (Masc_domain.Task (Masc_domain.Task_error.NotFound task_id))
           | Some task -> Ok task
         in
         let* () =
           Coord_task_classify.required_tool_claim_guard config ~agent_name ?agent_tool_names task
         in
         (* Cycle-prevention gate: refuse claim when do_not_reclaim_reason is set.
         The reason can come from cancel/release hard-stop logic or be applied
         directly by an operator. See PRs #7794 (schema), #7798 (cancel hook). *)
         let* () =
           match do_not_reclaim_reason_blocks_claim task.do_not_reclaim_reason with
           | None -> Ok ()
           | Some r ->
             Error
               (Masc_domain.Task (Masc_domain.Task_error.InvalidState
                  (Printf.sprintf "Task %s is blocked from re-claim: %s" task_id r)))
         in
         let (backlog, auto_released_ids) =
           auto_release_claimed_for_agent config ~agent_name ~exclude_task_id:task_id backlog
         in
         let* () =
           match task.task_status with
           | Todo ->
             (match
                active_ownership_conflict_for_claim
                  config
                  ~agent_name
                  ~requested_task_id:task_id
                  backlog
              with
              | None -> Ok ()
              | Some msg ->
                Error
                  (Masc_domain.Task (Masc_domain.Task_error.InvalidState msg)))
           | Claimed _
           | InProgress _
           | AwaitingVerification _
           | Done _
           | Cancelled _ -> Ok ()
         in
         (* fold_left to find+transform in a single pass without mutable refs.
         Uses polymorphic variants for inline state tracking. *)
         let claim_state, new_tasks =
           List.fold_left
             (fun (state, acc) (t : task) ->
                if t.id = task_id
                then (
                  match t.task_status with
                  | Todo ->
                    let t =
                      t
                      |> clear_soft_do_not_reclaim_reason
                      |> clear_stale_worktree_binding
                    in
                    let t' =
                      { t with
                        task_status =
                          Claimed { assignee = agent_name; claimed_at = now_iso () }
                      }
                    in
                    `Claimed_ok, t' :: acc
                  | Claimed { assignee; _ }
                  | InProgress { assignee; _ }
                  | AwaitingVerification { assignee; _ }
                    when assignee = agent_name -> `Already_mine, t :: acc
                  | Claimed { assignee; _ }
                  | InProgress { assignee; _ }
                  | AwaitingVerification { assignee; _ }
                  | Done { assignee; _ }
                  | Cancelled { cancelled_by = assignee; _ } ->
                    `Claimed_by assignee, t :: acc)
                else state, t :: acc)
             (`Not_found, [])
             backlog.tasks
         in
         let new_tasks = List.rev new_tasks in
         match claim_state with
         | `Not_found -> Error (Masc_domain.Task (Masc_domain.Task_error.NotFound task_id))
         | `Claimed_by other -> Error (Masc_domain.Task (Masc_domain.Task_error.AlreadyClaimed { task_id; by = other }))
         | `Already_mine ->
           Ok (Printf.sprintf "Task %s is already claimed by you" task_id)
         | `Claimed_ok ->
           let new_backlog =
             { tasks = new_tasks
             ; last_updated = now_iso ()
             ; version = backlog.version + 1
             }
           in
           write_backlog config new_backlog;
           Coord_task_classify.update_local_agent_state config ~agent_name (fun agent ->
             { agent with status = Busy; current_task = Some task_id });
           let _ =
             broadcast
               config
               ~from_agent:agent_name
               ~content:(Printf.sprintf "Claimed %s" task_id)
           in
           Coord_task_classify.emit_task_activity
             config
             ~agent_name
             ~task_id
             ~kind:(Event_kind.Task.to_string Event_kind.Task.Claimed)
             ~payload:(`Assoc [ "task_id", `String task_id ]);
           log_event
             config
             (`Assoc
                    [ "type", `String "task_claim"
                    ; "agent", `String agent_name
                    ; "actor_kind", `String (Coord_task_classify.task_actor_kind agent_name)
                    ; "task", `String task_id
                    ; "ts", `String (now_iso ())
                    ]);
           Coord_task_classify.observe_task_transition
             config
             ~agent_name
             ~task_id
             ~transition:Masc_domain.Claim
             ~details:
               (Coord_task_classify.task_transition_details
                  ~from_status:Masc_domain.Todo
                  ~to_status:
                    (Masc_domain.Claimed { assignee = agent_name; claimed_at = now_iso () })
                  ());
           (* task-103: best-effort auto-provision a sandbox worktree for
              docker keepers. The hook itself decides whether to act based
              on keeper sandbox_profile; failures are observed centrally and
              must not block the claim. *)
           (try
              (Atomic.get Coord_hooks.claim_post_provision_fn) config ~agent_name ~task_id
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
                Coord_hooks.observe_claim_post_provision_failure
                  ~site:"claim_task" ~agent_name ~task_id exn);
           (* Broadcast auto-released tasks (Claimed-only, preempted for this claim) *)
           broadcast_auto_releases config ~agent_name ~claimed_task_id:task_id auto_released_ids;
           let claim_msg =
             match auto_released_ids with
             | [] -> Printf.sprintf "%s claimed %s" agent_name task_id
             | ids ->
               Printf.sprintf "%s claimed %s (auto-released %s)"
                 agent_name task_id (String.concat ", " ids)
           in
           Ok claim_msg
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | e -> Error (Masc_domain.System (Masc_domain.System_error.IoError (Printexc.to_string e)))))
;;

(** Legacy string-returning claim_task. Delegates to [claim_task_r]. *)
let claim_task config ~agent_name ~task_id =
  match claim_task_r config ~agent_name ~task_id () with
  | Ok msg -> msg
  | Error e -> Masc_domain.to_string e
;;

(** Unified task transition (single entrypoint).
    When [~force:true], release/cancel/done bypass the assignee guard.
    Used by keeper for orphan task cleanup. *)
let release_handoff_texts handoff_context =
  let fields =
    match handoff_context with
    | None -> []
    | Some handoff_context ->
      [ Some handoff_context.summary
      ; handoff_context.reason
      ; handoff_context.next_step
      ; handoff_context.failure_mode
      ]
  in
  List.filter_map
    (function
     | None -> None
     | Some text ->
       let trimmed = String.trim text in
       if trimmed = "" then None else Some trimmed)
    fields
;;

let release_reclaim_policy = function
  | Some { reclaim_policy = Some policy; _ } -> Some policy
  | Some { reclaim_policy = None; _ } | None -> None
;;

let release_cycle_oscillation_hard_stop_threshold = 15

let release_cycle_oscillation_hard_stop_reason ~next_cycle =
  Printf.sprintf
    "auto: claim-release oscillation threshold reached (cycle=%d >= %d) - \
     operator review required before reclaim"
    next_cycle
    release_cycle_oscillation_hard_stop_threshold
;;

let derive_release_do_not_reclaim_reason (task : Masc_domain.task) handoff_context =
  match do_not_reclaim_reason_blocks_claim task.do_not_reclaim_reason with
  | Some _ as existing -> existing
  | None ->
    let first_text =
      match release_handoff_texts handoff_context with
      | text :: _ -> Some text
      | [] -> None
    in
    if release_reclaim_policy handoff_context = Some Masc_domain.Block_reclaim
    then
      Some
        (Option.value first_text ~default:"release hard-stop requested")
    else
      let next_cycle = task.cycle_count + 1 in
      if next_cycle >= release_cycle_oscillation_hard_stop_threshold
      then Some (release_cycle_oscillation_hard_stop_reason ~next_cycle)
      else None
;;
