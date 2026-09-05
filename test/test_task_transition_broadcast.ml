(** Every committed [transition_task_r] action reaches the workspace message
    log.

    [claim_task_r] has always broadcast "Claimed <id>", but the transition
    entry point emitted only an activity event. On the reference workspace that
    produced 53 [task.cancelled] activity events against 0 cancellation
    broadcasts over one month, while the claim path produced 196 messages: an
    operator reading the message log saw tasks get claimed and never saw one
    end, and a cancellation reason reached no reader at all.

    These tests drive the real transition path and read the durable message
    store, so a wording change is a failure and dropping the call entirely —
    the original defect — is also a failure. *)

module D = Masc_domain

open Masc

let now = "2026-08-04T00:00:00Z"
let owner = "alice"

let with_test_env f =
  let tmp_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc_transition_broadcast_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir tmp_dir 0o755;
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config tmp_dir in
  let _ = Workspace.init config ~agent_name:(Some owner) in
  (* [init] binds a namespace session and broadcasts that fact, so the
     assertions below read only what the transition itself produced. *)
  let baseline_seq =
    match Workspace.get_messages_raw config ~since_seq:0 ~limit:1 with
    | (latest : D.message) :: _ -> latest.seq
    | [] -> 0
  in
  Fun.protect
    ~finally:(fun () ->
      let _ = Workspace.reset config in
      try Unix.rmdir tmp_dir with Unix.Unix_error _ -> ())
    (fun () -> f config ~baseline_seq)
;;

let make_task ~id ~status : D.task =
  { id
  ; title = "test task"
  ; description = "desc"
  ; task_status = status
  ; priority = 3
  ; files = []
  ; created_at = now
  ; created_by = None
  ; predecessor_task_id = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; execution_links = Masc_domain.no_execution_links
  ; do_not_reclaim_reason = None
  ; skills = []
  }
;;

let seed config task =
  let backlog : D.backlog = { tasks = [ task ]; last_updated = now; version = 1 } in
  Workspace_backlog.write_backlog config backlog
;;

let contents config ~baseline_seq =
  Workspace.get_messages_raw config ~since_seq:baseline_seq ~limit:50
  |> List.map (fun (message : D.message) -> message.content)
;;

(* Every transition into [AwaitingVerification] persists a request before it
   commits, and this suite has no verification store. Both obligations stand
   in for one, so a cancellation reaches the wording under test rather than
   failing on absent storage. *)
let stub_verification_request ~task:_ ~assignee:_ ~verification_id:_ ~claim:_ = Ok ()

let transition config ~task_id ~action
      ?(prepare_verification_request = stub_verification_request) ?(reason = "")
      ?(notes = "") () =
  Workspace.transition_task_r
    config
    ~agent_name:owner
    ~task_id
    ~action
    ~prepare_verification_request
    ~notes
    ~reason
    ()
;;

let check_ok label = function
  | Ok (_ : string) -> ()
  | Error err -> Alcotest.failf "%s: %s" label (D.masc_error_to_string err)
;;

(* The cancellation reason is the payload an operator or the task's author
   needs; a bare "Cancelled task-1" would leave the message log as useless as
   the silent activity event it replaced.

   A producer's stop waits for a verdict, so the row says the stop was asked
   for. It used to say "Cancelled task-1" for a Task that was still awaiting
   one — and could still be sent back to the producer. *)
let test_cancel_broadcasts_reason () =
  with_test_env (fun config ~baseline_seq ->
    seed config
      (make_task ~id:"task-1" ~status:(D.InProgress { assignee = owner; started_at = now }));
    check_ok "cancel"
      (transition config ~task_id:"task-1" ~action:D.Cancel
         ~reason:"BLOCKED: service absent from sandbox" ());
    Alcotest.(check (list string))
      "the requested cancellation reaches the message log with its reason"
      [ "Cancellation requested for task-1 - BLOCKED: service absent from sandbox" ]
      (contents config ~baseline_seq))
;;

(* An unclaimed Task has no producer to judge, so its cancel is terminal on the
   spot and says so. Same action, two statuses, two sentences. *)
let test_cancel_of_an_unclaimed_task_is_announced_as_terminal () =
  with_test_env (fun config ~baseline_seq ->
    seed config (make_task ~id:"task-13" ~status:D.Todo);
    check_ok "cancel"
      (transition config ~task_id:"task-13" ~action:D.Cancel
         ~reason:"the defect was fixed elsewhere" ());
    Alcotest.(check (list string))
      "an unclaimed cancellation is announced as done"
      [ "Cancelled task-13 - the defect was fixed elsewhere" ]
      (contents config ~baseline_seq))
;;

let test_cancel_without_reason_broadcasts_bare () =
  with_test_env (fun config ~baseline_seq ->
    seed config (make_task ~id:"task-2" ~status:D.Todo);
    check_ok "cancel" (transition config ~task_id:"task-2" ~action:D.Cancel ());
    Alcotest.(check (list string))
      "empty reason omits the separator"
      [ "Cancelled task-2" ]
      (contents config ~baseline_seq))
;;

(* Completion never commits here — the lifecycle demands verification first,
   and the approved verdict commits through [commit_verdict_r], which posts to
   Board. Pinned so that a future "Completed <id>" broadcast is recognised as
   either a lifecycle change or a duplicate of the Board verdict. *)
let test_done_action_is_rejected_and_silent () =
  with_test_env (fun config ~baseline_seq ->
    seed config
      (make_task ~id:"task-3" ~status:(D.InProgress { assignee = owner; started_at = now }));
    (match
       transition config ~task_id:"task-3" ~action:D.Done_action
         ~notes:"evidence at /tmp/proof" ()
     with
     | Ok message -> Alcotest.failf "expected verification requirement, got: %s" message
     | Error (_ : D.masc_error) -> ());
    Alcotest.(check (list string))
      "no message for a completion that never committed"
      []
      (contents config ~baseline_seq))
;;

let test_release_broadcasts_reason () =
  with_test_env (fun config ~baseline_seq ->
    seed config
      (make_task ~id:"task-4" ~status:(D.Claimed { assignee = owner; claimed_at = now }));
    check_ok "release"
      (transition config ~task_id:"task-4" ~action:D.Release
         ~reason:"handing back to the backlog" ());
    Alcotest.(check (list string))
      "release reaches the message log with its reason"
      [ "Released task-4 - handing back to the backlog" ]
      (contents config ~baseline_seq))
;;

let test_claim_and_start_broadcast () =
  with_test_env (fun config ~baseline_seq ->
    seed config (make_task ~id:"task-5" ~status:D.Todo);
    check_ok "claim" (transition config ~task_id:"task-5" ~action:D.Claim ());
    check_ok "start" (transition config ~task_id:"task-5" ~action:D.Start ());
    Alcotest.(check (list string))
      "both ownership steps reach the message log, newest first"
      [ "Started task-5"; "Claimed task-5" ]
      (contents config ~baseline_seq))
;;

(* Submission publishes the request, its criteria, and its evidence refs to
   Board. A message row would restate a poorer version of that post, so the
   transition stays silent here on purpose. *)
let test_submit_defers_to_board () =
  with_test_env (fun config ~baseline_seq ->
    seed config
      (make_task ~id:"task-8" ~status:(D.InProgress { assignee = owner; started_at = now }));
    check_ok "submit"
      (transition config ~task_id:"task-8" ~action:D.Submit_for_verification
         ~notes:"evidence at /tmp/proof" ());
    Alcotest.(check (list string))
      "submission does not duplicate its Board post as a message"
      []
      (contents config ~baseline_seq))
;;

(* [release_task_r] takes no [reason]: it forwards only [handoff_context], and
   the production release tool requires one for a strict release. Driving the
   real wrapper here rather than [transition] pins the entry point that was
   publishing a bare "Released <id>" while holding the explanation. *)
let test_release_wrapper_broadcasts_its_handoff_reason () =
  with_test_env (fun config ~baseline_seq ->
    seed config
      (make_task ~id:"task-10" ~status:(D.Claimed { assignee = owner; claimed_at = now }));
    let handoff : D.task_handoff_context =
      { summary = "sandbox lacks the request-menu service"
      ; reason = Some "cannot verify without the service"
      ; next_step = Some "re-file once the sandbox ships it"
      ; failure_mode = None
      ; reclaim_policy = None
      ; evidence_refs = []
      ; updated_at = None
      ; updated_by = None
      }
    in
    check_ok "release"
      (Workspace.release_task_r config ~agent_name:owner ~task_id:"task-10"
         ~handoff_context:handoff ());
    Alcotest.(check (list string))
      "the handoff reason reaches the message log"
      [ "Released task-10 - cannot verify without the service" ]
      (contents config ~baseline_seq))
;;

(* A strict release is rejected without [handoff_context.summary] while
   [reason] stays optional, so a release whose whole explanation is its summary
   is a valid and ordinary shape. Reading only [reason] published a bare
   "Released <id>" and dropped text the caller was required to supply. *)
let test_release_broadcasts_a_summary_only_handoff () =
  with_test_env (fun config ~baseline_seq ->
    seed config
      (make_task ~id:"task-12" ~status:(D.Claimed { assignee = owner; claimed_at = now }));
    let handoff : D.task_handoff_context =
      { summary = "returning to the backlog until the sandbox ships the service"
      ; reason = None
      ; next_step = None
      ; failure_mode = None
      ; reclaim_policy = None
      ; evidence_refs = []
      ; updated_at = None
      ; updated_by = None
      }
    in
    check_ok "release"
      (Workspace.release_task_r config ~agent_name:owner ~task_id:"task-12"
         ~handoff_context:handoff ());
    Alcotest.(check (list string))
      "the summary reaches the message log"
      [ "Released task-12 - returning to the backlog until the sandbox ships the service" ]
      (contents config ~baseline_seq))
;;

(* An explicit [reason] outranks the handoff context: the caller stated why for
   this transition, while the handoff context describes the work's state. *)
let test_explicit_reason_outranks_handoff_context () =
  with_test_env (fun config ~baseline_seq ->
    seed config
      (make_task ~id:"task-11" ~status:(D.InProgress { assignee = owner; started_at = now }));
    check_ok "cancel"
      (Workspace.transition_task_r config ~agent_name:owner ~task_id:"task-11"
         ~prepare_verification_request:stub_verification_request
         ~action:D.Cancel ~notes:""
         ~reason:"superseded by task-12"
         ~handoff_context:
           { summary = "partial"
           ; reason = Some "older note"
           ; next_step = None
           ; failure_mode = None
           ; reclaim_policy = None
           ; evidence_refs = []
           ; updated_at = None
           ; updated_by = None
           }
         ());
    Alcotest.(check (list string))
      "the stated reason wins"
      [ "Cancellation requested for task-11 - superseded by task-12" ]
      (contents config ~baseline_seq))
;;

(* A note already on the Task is the previous owner's: a release summary kept
   across the claim so the incoming owner can read it (RFC-0365). It is not
   this owner's reason to stop. Resolving the cancel reason from it put the
   previous owner's sentence before the operator as the claim, while the
   broadcast, reading only this call's arguments, announced no reason at all.
   The record, the committed Task and the message log read one value: this
   call's [reason] or [handoff_context] — and with neither, the cancel is
   refused rather than explained by someone else. *)
let held_with_the_previous_owners_note ~id =
  { (make_task ~id ~status:(D.InProgress { assignee = owner; started_at = now })) with
    handoff_context =
      Some
        { summary = "previous owner: half done, see branch wip/1"
        ; reason = None
        ; next_step = None
        ; failure_mode = None
        ; reclaim_policy = None
        ; evidence_refs = []
        ; updated_at = None
        ; updated_by = None
        }
  }
;;

(* The activity event a cancel emits, captured through the hook the emitter
   calls; this suite has no activity store. *)
let with_captured_activity f =
  let previous = Atomic.get Workspace_hooks.activity_emit_fn in
  let emitted = ref [] in
  Fun.protect
    ~finally:(fun () -> Atomic.set Workspace_hooks.activity_emit_fn previous)
    (fun () ->
       Atomic.set
         Workspace_hooks.activity_emit_fn
         (fun _config ~actor:_ ?subject:_ ~kind ~payload ~tags:_ () ->
            emitted := (kind, payload) :: !emitted);
       f (fun () -> List.rev !emitted))
;;

let cancelled_event_reasons emitted =
  List.filter_map
    (fun (kind, payload) ->
       if String.equal kind (Event_kind.Task.to_string Event_kind.Task.Cancelled)
       then Some (Yojson.Safe.Util.member "reason" payload)
       else None)
    (emitted ())
;;

let test_cancel_does_not_borrow_the_previous_owners_note () =
  with_test_env (fun config ~baseline_seq ->
  with_captured_activity (fun emitted ->
    seed config (held_with_the_previous_owners_note ~id:"task-14");
    let recorded = ref None in
    let capture ~task:_ ~assignee:_ ~verification_id:_ ~claim =
      recorded := Some claim;
      Ok ()
    in
    (match
       transition config ~task_id:"task-14" ~action:D.Cancel
         ~prepare_verification_request:capture ()
     with
     | Ok message ->
       Alcotest.failf "a cancel with no reason of its own was accepted: %s" message
     | Error (D.Task (D.Task_error.InvalidState _)) -> ()
     | Error err -> Alcotest.failf "unexpected rejection: %s" (D.masc_error_to_string err));
    Alcotest.(check bool) "no record is written for a refused cancel" true
      (Option.is_none !recorded);
    Alcotest.(check (list string)) "a refused cancel is silent" []
      (contents config ~baseline_seq);
    check_ok "cancel"
      (transition config ~task_id:"task-14" ~action:D.Cancel
         ~prepare_verification_request:capture ~reason:"the premise is gone" ());
    (match !recorded with
     | Some (D.Cancellation_reason { reason }) ->
       Alcotest.(check string) "the record carries this owner's reason"
         "the premise is gone" reason
     | Some (D.Completion_evidence _) -> Alcotest.fail "a cancel wrote a completion claim"
     | None -> Alcotest.fail "the cancel wrote no record");
    Alcotest.(check (list string)) "the message log carries the same reason"
      [ "Cancellation requested for task-14 - the premise is gone" ]
      (contents config ~baseline_seq);
    Alcotest.(check bool) "the activity event carries the same reason" true
      (cancelled_event_reasons emitted = [ `String "the premise is gone" ]);
    match List.find_opt (fun (task : D.task) -> String.equal task.id "task-14")
            (Workspace.get_tasks_raw config) with
    | Some task ->
      Alcotest.(check bool) "the previous owner's note does not ride on the cancel" true
        (Option.is_none task.handoff_context)
    | None -> Alcotest.fail "task-14 vanished"))
;;

(* A stop stated only in handoff_context.summary — the shape the tool schema
   asks for — reaches every surface with that sentence. The record, the
   message log and the committed Task already read it; the activity event
   read the bare [reason] argument and published null for exactly this call. *)
let test_cancel_stated_in_the_summary_reaches_every_surface () =
  with_test_env (fun config ~baseline_seq ->
  with_captured_activity (fun emitted ->
    seed config
      (make_task ~id:"task-15" ~status:(D.InProgress { assignee = owner; started_at = now }));
    let recorded = ref None in
    let capture ~task:_ ~assignee:_ ~verification_id:_ ~claim =
      recorded := Some claim;
      Ok ()
    in
    check_ok "cancel"
      (Workspace.transition_task_r config ~agent_name:owner ~task_id:"task-15"
         ~prepare_verification_request:capture ~action:D.Cancel
         ~handoff_context:
           { summary = "the premise this rests on is gone"
           ; reason = None
           ; next_step = None
           ; failure_mode = None
           ; reclaim_policy = None
           ; evidence_refs = []
           ; updated_at = None
           ; updated_by = None
           }
         ());
    (match !recorded with
     | Some (D.Cancellation_reason { reason }) ->
       Alcotest.(check string) "the record carries the summary"
         "the premise this rests on is gone" reason
     | Some (D.Completion_evidence _) -> Alcotest.fail "a cancel wrote a completion claim"
     | None -> Alcotest.fail "the cancel wrote no record");
    Alcotest.(check (list string)) "the message log carries the summary"
      [ "Cancellation requested for task-15 - the premise this rests on is gone" ]
      (contents config ~baseline_seq);
    Alcotest.(check bool) "the activity event carries the summary, not null" true
      (cancelled_event_reasons emitted = [ `String "the premise this rests on is gone" ]);
    match List.find_opt (fun (task : D.task) -> String.equal task.id "task-15")
            (Workspace.get_tasks_raw config) with
    | Some { handoff_context = Some { summary; _ }; _ } ->
      Alcotest.(check string) "the committed Task keeps the same note"
        "the premise this rests on is gone" summary
    | Some { handoff_context = None; _ } -> Alcotest.fail "the cancel's own note was dropped"
    | None -> Alcotest.fail "task-15 vanished"))
;;

(* The idempotent no-op returns before the commit, so it must not manufacture a
   message for a transition that never happened. *)
let test_noop_transition_is_silent () =
  with_test_env (fun config ~baseline_seq ->
    seed config
      (make_task ~id:"task-6"
         ~status:(D.Cancelled { cancelled_by = owner; cancelled_at = now; reason = None }));
    check_ok "cancel no-op" (transition config ~task_id:"task-6" ~action:D.Cancel ());
    Alcotest.(check (list string)) "no message for a no-op" [] (contents config ~baseline_seq))
;;

(* A rejected transition must not announce work that did not happen. *)
let test_rejected_transition_is_silent () =
  with_test_env (fun config ~baseline_seq ->
    seed config
      (make_task ~id:"task-7"
         ~status:(D.InProgress { assignee = "bob"; started_at = now }));
    (match transition config ~task_id:"task-7" ~action:D.Cancel ~reason:"not mine" () with
     | Ok message -> Alcotest.failf "expected rejection, got: %s" message
     | Error (_ : D.masc_error) -> ());
    Alcotest.(check (list string))
      "no message for a rejected transition"
      []
      (contents config ~baseline_seq))
;;

let () =
  Alcotest.run
    "task transition broadcast"
    [ ( "committed transitions"
      , [ Alcotest.test_case "cancel carries its reason" `Quick
            test_cancel_broadcasts_reason
        ; Alcotest.test_case "an unclaimed cancel is terminal" `Quick
            test_cancel_of_an_unclaimed_task_is_announced_as_terminal
        ; Alcotest.test_case "cancel without reason" `Quick
            test_cancel_without_reason_broadcasts_bare
        ; Alcotest.test_case "release carries its reason" `Quick
            test_release_broadcasts_reason
        ; Alcotest.test_case "claim and start" `Quick test_claim_and_start_broadcast
        ; Alcotest.test_case "submit defers to its Board post" `Quick
            test_submit_defers_to_board
        ; Alcotest.test_case "release wrapper carries its handoff reason" `Quick
            test_release_wrapper_broadcasts_its_handoff_reason
        ; Alcotest.test_case "release carries a summary-only handoff" `Quick
            test_release_broadcasts_a_summary_only_handoff
        ; Alcotest.test_case "cancel does not borrow the previous owner's note" `Quick
            test_cancel_does_not_borrow_the_previous_owners_note
        ; Alcotest.test_case "cancel stated in the summary reaches every surface" `Quick
            test_cancel_stated_in_the_summary_reaches_every_surface
        ; Alcotest.test_case "explicit reason outranks handoff context" `Quick
            test_explicit_reason_outranks_handoff_context
        ] )
    ; ( "uncommitted transitions"
      , [ Alcotest.test_case "no-op is silent" `Quick test_noop_transition_is_silent
        ; Alcotest.test_case "rejected is silent" `Quick
            test_rejected_transition_is_silent
        ; Alcotest.test_case "done_action is rejected and silent" `Quick
            test_done_action_is_rejected_and_silent
        ] )
    ]
;;
