(** Workspace_task_claim — claim_task, claim_task_r, release/reclaim helpers.

    Extracted from Workspace_task to separate claim logic from classification,
    creation, and transitions.  All bindings are re-exported by [Workspace_task]
    via [include Workspace_task_claim]. *)

open Masc_domain
include Workspace_utils
include Workspace_state
open Workspace_backlog
open Workspace_identity
include Workspace_broadcast
open Workspace_backlog
open Workspace_identity

let clear_reclaim_decision (task : Masc_domain.task) =
  match task.reclaim_policy with
  | Some Masc_domain.Block_reclaim -> task
  | Some Masc_domain.Allow_reclaim | None ->
    { task with reclaim_policy = None; do_not_reclaim_reason = None }
;;

let active_owned_task_ids_for_agent config ~agent_name (backlog : Masc_domain.backlog)
  =
  backlog.tasks
  |> List.filter_map (fun (task : Masc_domain.task) ->
         match task.task_status with
         | Claimed { assignee; _ } | InProgress { assignee; _ }
           when Workspace_task_classify.same_task_actor config assignee agent_name ->
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
    "Agent %s has task(s) in progress: %s. Use keeper_task_done (task_id + result + evidence_refs) \
     to finish them before claiming %s."
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

(** RFC-0088 §1 child step (issue #18839): typed surface for the
    implicit auto-release that [task_claim_next] performs when the
    agent already holds another task. Previously the only signal was
    a substring in the [Ok msg] string ["… (auto-released X, Y)"];
    MCP handlers and tests had to re-parse it. Lifting it into a
    typed field lets callers — including the MCP envelope that feeds
    the LLM keeper — react without string parsing, which is the
    enabling step before behaviour change (reject + explicit release)
    can be staged. *)
type claim_outcome = {
  message : string;
  auto_released_task_ids : string list;
}

(** Result-returning version of claim_task for type-safe error handling. *)
let claim_task_r config ~agent_name ~task_id ()
  : claim_outcome Masc_domain.masc_result
  =
  let open Result.Syntax in
  let* () = if not (is_initialized config) then Error (Masc_domain.System Masc_domain.System_error.NotInitialized) else Ok () in
  let* () =
    match validate_agent_name_r agent_name, validate_task_id_r task_id with
    | Error e, _ -> Error e
    | _, Error e -> Error e
    | Ok _, Ok _ -> Ok ()
  in
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  let claim_result =
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
         (* Claim gate: only typed policy blocks Todo reclaim.
         do_not_reclaim_reason is an operator-facing explanation, not state;
         task-local runtime repair is not part of the claim gate. *)
         let* () =
           match Masc_domain.task_claim_decision task with
           | Claim_unavailable (Claim_block_reclaim_policy r) ->
             Error
               (Masc_domain.Task (Masc_domain.Task_error.InvalidState
                  (Printf.sprintf "Task %s is blocked from re-claim: %s" task_id r)))
           | Claim_available _ | Claim_unavailable (Claim_block_not_todo _) -> Ok ()
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
                  (* RFC-0220 §3.5: one claim decision, shared with the
                     auto-claim path ([claim_next_r]). [resolve_claim] owns the
                     self-check (normalized via [same_task_actor]) and, for a
                     cross-agent verification claim, binds the verifier into the
                     [AwaitingVerification] status — no longer a status-
                     preserving no-op that deferred verifier identity to a
                     separate store (#19314). *)
                  match
                    Workspace_task_lifecycle.resolve_claim
                      ~same_actor:(fun a ->
                        Workspace_task_classify.same_task_actor config a agent_name)
                      ~agent_name
                      ~now:(now_iso ())
                      t
                  with
                  | Workspace_task_lifecycle.Worker_claim status ->
                    let t = clear_reclaim_decision t in
                    `Claimed_ok, { t with task_status = status } :: acc
                  | Workspace_task_lifecycle.Verifier_claim status ->
                    `Claimed_verification, { t with task_status = status } :: acc
                  | Workspace_task_lifecycle.Self_owned -> `Already_mine, t :: acc
                  | Workspace_task_lifecycle.Held_by_other holder ->
                    `Claimed_by holder, t :: acc
                  | Workspace_task_lifecycle.Blocked_by_reclaim_policy reason ->
                    `Claim_blocked reason, t :: acc)
                else state, t :: acc)
             (`Not_found, [])
             backlog.tasks
         in
         let new_tasks = List.rev new_tasks in
         match claim_state with
         | `Not_found -> Error (Masc_domain.Task (Masc_domain.Task_error.NotFound task_id))
         | `Claim_blocked reason ->
           Error
             (Masc_domain.Task
                (Masc_domain.Task_error.InvalidState
                   (Printf.sprintf "Task %s is blocked from re-claim: %s" task_id reason)))
         | `Claimed_by other -> Error (Masc_domain.Task (Masc_domain.Task_error.AlreadyClaimed { task_id; by = other }))
         | `Already_mine ->
           Ok
             (`Existing_claim
               { message = Printf.sprintf "Task %s is already claimed by you" task_id
               ; auto_released_task_ids = []
               })
         | `Claimed_verification ->
           (* Issue #19314 / RFC-0220 §3.5: cross-agent verification dispatch.
              The task stays [AwaitingVerification]; [resolve_claim] has bound
              this agent as the verifier in [phase] (Verifier_assigned). Persist
              that status and point the agent at the task. The verifier binding
              now lives in the task FSM (single authority via [phase]), so the
              former defer-to-dispatch-loop workaround is gone — no cross-lib
              call into [Verification.assign_verifier] is needed. *)
           let claimed_task =
             List.find (fun (t : Masc_domain.task) -> String.equal t.id task_id) new_tasks
           in
           let new_backlog =
             { tasks = new_tasks
             ; last_updated = now_iso ()
             ; version = backlog.version + 1
             }
           in
           write_backlog
             ~after_commit:(fun () ->
               Task_cache_invariant.clear_stale_agent_task config
                 ~agent_name ~task_id ~status:claimed_task.task_status
                 ~module_name:"claim_task_r.verification")
             config new_backlog;
           Workspace_task_classify.update_local_agent_state config ~agent_name (fun agent ->
             { agent with status = Busy; current_task = Some task_id });
           let _ =
             broadcast
               config
               ~from_agent:agent_name
               ~content:(Printf.sprintf "Assigned as verifier for %s" task_id)
           in
           Workspace_task_classify.emit_task_activity
             config
             ~agent_name
             ~task_id
             ~kind:(Event_kind.Task.to_string Event_kind.Task.Claimed)
             ~payload:(`Assoc
               [ "task_id", `String task_id
               ; "verification_dispatch", `Bool true
               ]);
           log_event
             config
             (`Assoc
               [ "type", `String "task_claim_verification"
               ; "agent", `String agent_name
               ; "actor_kind", `String (Workspace_task_classify.task_actor_kind agent_name)
               ; "task", `String task_id
               ; "ts", `String (now_iso ())
               ]);
           Ok
             (`New_claim
               { message = Printf.sprintf "%s assigned as verifier for %s" agent_name task_id
               ; auto_released_task_ids = []
               })
         | `Claimed_ok ->
           let claimed_task =
             List.find (fun (t : Masc_domain.task) -> String.equal t.id task_id) new_tasks
           in
           let new_backlog =
             { tasks = new_tasks
             ; last_updated = now_iso ()
             ; version = backlog.version + 1
             }
           in
           write_backlog
             ~after_commit:(fun () ->
               Task_cache_invariant.clear_stale_agent_task config
                 ~agent_name ~task_id ~status:claimed_task.task_status
                 ~module_name:"claim_task_r.claimed_ok")
             config new_backlog;
           Workspace_task_classify.update_local_agent_state config ~agent_name (fun agent ->
             { agent with status = Busy; current_task = Some task_id });
           let _ =
             broadcast
               config
               ~from_agent:agent_name
               ~content:(Printf.sprintf "Claimed %s" task_id)
           in
           Workspace_task_classify.emit_task_activity
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
                    ; "actor_kind", `String (Workspace_task_classify.task_actor_kind agent_name)
                    ; "task", `String task_id
                    ; "ts", `String (now_iso ())
                    ]);
           Workspace_task_classify.observe_task_transition
             config
             ~agent_name
             ~task_id
             ~transition:Masc_domain.Claim
             ~details:
               (Workspace_task_classify.task_transition_details
                  ~from_status:Masc_domain.Todo
                  ~to_status:
                    (Masc_domain.Claimed { assignee = agent_name; claimed_at = now_iso () })
                  ());
           let claim_msg = Printf.sprintf "%s claimed %s" agent_name task_id in
           Ok
             (`New_claim
               { message = claim_msg; auto_released_task_ids = [] })
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | e -> Error (Masc_domain.System (Masc_domain.System_error.IoError (Printexc.to_string e)))))
  in
  match claim_result with
  | Ok (`New_claim outcome) -> Ok outcome
  | Ok (`Existing_claim outcome) -> Ok outcome
  | Error _ as err -> err
;;

(** Legacy string-returning claim_task. Delegates to [claim_task_r]. *)
let claim_task config ~agent_name ~task_id =
  match claim_task_r config ~agent_name ~task_id () with
  | Ok outcome -> outcome.message
  | Error e -> Masc_domain.to_string e
;;

(** Unified task transition (single entrypoint).
    When [~force:true], release/cancel/done bypass the assignee guard.
    Used by keeper for orphan task cleanup. *)
let release_handoff_texts (handoff_context : Masc_domain.task_handoff_context option) =
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

let release_reclaim_policy (handoff_context : Masc_domain.task_handoff_context option) =
  match handoff_context with
  | Some ({ reclaim_policy = Some policy; _ } : Masc_domain.task_handoff_context) ->
    Some policy
  | Some ({ reclaim_policy = None; _ } : Masc_domain.task_handoff_context) | None -> None
;;

let derive_release_do_not_reclaim_reason
      (task : Masc_domain.task)
      (handoff_context : Masc_domain.task_handoff_context option)
  =
  if release_reclaim_policy handoff_context = Some Masc_domain.Block_reclaim
  then (
    match release_handoff_texts handoff_context with
    | text :: _ -> Some text
    | [] -> Some "release hard-stop requested")
  else
    match task.reclaim_policy with
    | Some Masc_domain.Block_reclaim -> task.do_not_reclaim_reason
    | Some Masc_domain.Allow_reclaim | None -> None
;;

let derive_release_reclaim_policy
      (task : Masc_domain.task)
      (handoff_context : Masc_domain.task_handoff_context option)
  =
  match release_reclaim_policy handoff_context with
  | Some policy -> Some policy
  | None -> (
    match task.reclaim_policy with
    | Some Masc_domain.Block_reclaim -> Some Masc_domain.Block_reclaim
    | Some Masc_domain.Allow_reclaim | None -> None)
;;
