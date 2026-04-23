(** Comprehensive coverage tests for Coord module

    Target: 35+ additional tests covering:
    - Batch operations
    - Task transitions (claim_next, update_priority, cancel, release)
    - Pause/Resume functionality
    - GC and cleanup
    - Result-returning variants (_r functions)
    - Raw data accessors
    - Edge cases not covered in test_room.ml
*)

open Masc_mcp

(* ============================================================ *)
(* Test Helpers                                                  *)
(* ============================================================ *)

(** Check for success emoji *)
let contains_check result =
  String.length result >= 3 && String.sub result 0 3 = "\xE2\x9C\x85"  (* ✅ *)

(** Check for warning emoji *)
let contains_warning result =
  String.length result >= 3 && String.sub result 0 3 = "\xE2\x9A\xA0"  (* ⚠ *)

(** Check for error emoji *)
let contains_error result =
  String.length result >= 3 && String.sub result 0 3 = "\xE2\x9D\x8C"  (* ❌ *)

(** Check for cancel emoji *)
let _contains_cancel result =
  String.length result >= 4 && String.sub result 0 4 = "\xF0\x9F\x9A\xAB"  (* 🚫 *)

(** Substring check helper *)
let str_contains s substring =
  let len_s = String.length s in
  let len_sub = String.length substring in
  if len_sub > len_s then false
  else
    let rec check i =
      if i > len_s - len_sub then false
      else if String.sub s i len_sub = substring then true
      else check (i + 1)
    in
    check 0

(** Create fresh test environment with cleanup.
    Wrapped in Eio_main.run because Coord.init uses Eio.Mutex internally. *)
let with_test_env f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_coverage_%d_%d" (Unix.getpid ())
       (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;
  let config = Coord.default_config tmp_dir in
  let _ = Coord.init config ~agent_name:(Some "claude") in
  try
    f config;
    let _ = Coord.reset config in
    Unix.rmdir tmp_dir
  with e ->
    let _ = Coord.reset config in
    Unix.rmdir tmp_dir;
    raise e

let latest_ring_seq () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> entry.seq
  | [] -> 0

let detail_string details key =
  match details with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
      | Some (`String value) -> Some value
      | _ -> None)
  | _ -> None

let detail_matches details expected =
  List.for_all
    (fun (key, value) ->
      match detail_string details key with
      | Some actual -> String.equal actual value
      | None -> false)
    expected

let find_agent_name_by_prefix config prefix =
  match
    List.find_opt
      (fun (agent : Types.agent) -> String.starts_with ~prefix agent.name)
      (Coord.get_agents_raw config)
  with
  | Some agent -> agent.name
  | None -> Alcotest.failf "agent with prefix %s not found" prefix

let transition_done_r config ~agent_name ~task_id ~notes =
  Coord.transition_task_r config ~agent_name ~task_id
    ~action:Types.Done_action ~notes ()

let transition_done config ~agent_name ~task_id ~notes =
  match transition_done_r config ~agent_name ~task_id ~notes with
  | Ok msg -> msg
  | Error err -> Types.masc_error_to_string err

let audit_has_entry entries ~agent_id ~action_pred ~details =
  List.exists
    (fun (entry : Audit_log.audit_entry) ->
      String.equal entry.agent_id agent_id
      && action_pred entry.action
      && detail_matches entry.details details)
    entries

let ring_has_entry entries ~details =
  List.exists
    (fun (entry : Log.Ring.entry) -> detail_matches entry.details details)
    entries

(* ============================================================ *)
(* Batch Operations Tests                                        *)
(* ============================================================ *)

let test_batch_add_tasks () =
  with_test_env (fun config ->
    let tasks = [
      ("Task A", 1, "Description A", None);
      ("Task B", 2, "Description B", None);
      ("Task C", 3, "Description C", None);
    ] in
    let result = Coord.batch_add_tasks config tasks in
    Alcotest.(check bool) "batch add success" true (contains_check result);
    Alcotest.(check bool) "contains task-001" true (str_contains result "task-001");
    Alcotest.(check bool) "contains task-003" true (str_contains result "task-003")
  )

let test_batch_add_empty_list () =
  with_test_env (fun config ->
    let result = Coord.batch_add_tasks config [] in
    Alcotest.(check bool) "batch add empty returns something" true (String.length result > 0)
  )

let test_batch_add_single_task () =
  with_test_env (fun config ->
    let result = Coord.batch_add_tasks config [("Single", 1, "Only one", None)] in
    Alcotest.(check bool) "single task batch" true (contains_check result)
  )

let test_batch_add_preserves_priorities () =
  with_test_env (fun config ->
    let tasks = [
      ("High Priority", 1, "", None);
      ("Low Priority", 5, "", None);
    ] in
    let _ = Coord.batch_add_tasks config tasks in
    let task_list = Coord.list_tasks config in
    Alcotest.(check bool) "shows priorities" true
      (str_contains task_list "[1]" && str_contains task_list "[5]")
  )

(* ============================================================ *)
(* Claim Next Tests                                              *)
(* ============================================================ *)

let test_claim_next_basic () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test Task" ~priority:1 ~description:"" in
    let result = Coord.claim_next config ~agent_name:"claude" in
    Alcotest.(check bool) "claim next success" true (contains_check result);
    Alcotest.(check bool) "has task id" true (str_contains result "task-001")
  )

let test_claim_next_priority_order () =
  with_test_env (fun config ->
    (* Add tasks in non-priority order *)
    let _ = Coord.add_task config ~title:"Low" ~priority:5 ~description:"" in
    let _ = Coord.add_task config ~title:"High" ~priority:1 ~description:"" in
    let _ = Coord.add_task config ~title:"Medium" ~priority:3 ~description:"" in

    (* Should claim highest priority (lowest number) first *)
    let result = Coord.claim_next config ~agent_name:"claude" in
    Alcotest.(check bool) "claims high priority first" true
      (str_contains result "[P1]" || str_contains result "task-002")
  )

let test_claim_next_empty_backlog () =
  with_test_env (fun config ->
    let result = Coord.claim_next config ~agent_name:"claude" in
    Alcotest.(check bool) "no tasks message" true (str_contains result "No unclaimed")
  )

let test_claim_next_all_claimed () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Only Task" ~priority:1 ~description:"" in
    let _ = Coord.claim_task config ~agent_name:"gemini" ~task_id:"task-001" in

    let result = Coord.claim_next config ~agent_name:"claude" in
    Alcotest.(check bool) "no unclaimed tasks" true (str_contains result "No unclaimed")
  )

let test_claim_next_skips_done_and_cancelled () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Done Task" ~priority:1 ~description:"" in
    let _ = Coord.add_task config ~title:"Cancelled Task" ~priority:2 ~description:"" in
    let _ = Coord.add_task config ~title:"Todo Task" ~priority:3 ~description:"" in
    let _ = Coord.claim_task config ~agent_name:"alice" ~task_id:"task-001" in
    let _ = transition_done config ~agent_name:"alice" ~task_id:"task-001" ~notes:"done" in
    (match
       Coord.cancel_task_r config ~agent_name:"alice" ~task_id:"task-002"
         ~reason:"cancelled"
     with
    | Ok _ -> ()
    | Error e -> Alcotest.fail (Types.masc_error_to_string e));

    let result = Coord.claim_next config ~agent_name:"claude" in
    Alcotest.(check bool) "claims the remaining todo task" true
      (str_contains result "task-003");

    let tasks = Coord.get_tasks_raw config in
    let status_of task_id =
      match List.find_opt (fun (t : Types.task) -> String.equal t.id task_id) tasks with
      | Some task -> Types.task_status_to_string task.task_status
      | None -> Alcotest.failf "missing task %s" task_id
    in
    Alcotest.(check string) "done task preserved" "done" (status_of "task-001");
    Alcotest.(check string) "cancelled task preserved" "cancelled" (status_of "task-002");
    Alcotest.(check string) "todo task claimed" "claimed" (status_of "task-003")
  )

let test_claim_next_terminal_only_backlog () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Done Task" ~priority:1 ~description:"" in
    let _ = Coord.add_task config ~title:"Cancelled Task" ~priority:2 ~description:"" in
    let _ = Coord.claim_task config ~agent_name:"alice" ~task_id:"task-001" in
    let _ = transition_done config ~agent_name:"alice" ~task_id:"task-001" ~notes:"done" in
    (match
       Coord.cancel_task_r config ~agent_name:"alice" ~task_id:"task-002"
         ~reason:"cancelled"
     with
    | Ok _ -> ()
    | Error e -> Alcotest.fail (Types.masc_error_to_string e));

    let result = Coord.claim_next config ~agent_name:"claude" in
    Alcotest.(check bool) "terminal backlog reports no unclaimed tasks" true
      (str_contains result "No unclaimed")
  )

let test_claim_next_consecutive () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"First" ~priority:1 ~description:"" in
    let _ = Coord.add_task config ~title:"Second" ~priority:2 ~description:"" in

    let r1 = Coord.claim_next config ~agent_name:"claude" in
    let r2 = Coord.claim_next config ~agent_name:"gemini" in

    Alcotest.(check bool) "first claim success" true (contains_check r1);
    Alcotest.(check bool) "second claim success" true (contains_check r2);
    (* Different agents should get different tasks *)
    Alcotest.(check bool) "different tasks" true
      (str_contains r1 "task-001" || str_contains r2 "task-002")
  )

let test_claim_next_reconciles_stale_agent_current_task () =
  with_test_env (fun config ->
    let agent_name =
      match Coord.get_agents_raw config with
      | [ agent ] -> agent.Types.name
      | _ -> Alcotest.fail "expected exactly one joined agent"
    in
    let _ = Coord.add_task config ~title:"Done already" ~priority:1 ~description:"" in
    let _ = Coord.claim_task config ~agent_name ~task_id:"task-001" in
    (match
       transition_done_r config ~agent_name ~task_id:"task-001" ~notes:"done"
     with
    | Ok _ -> ()
    | Error e -> Alcotest.fail (Types.masc_error_to_string e));
    let agent_file =
      Filename.concat (Coord.agents_dir config)
        (Coord.safe_filename agent_name ^ ".json")
    in
    let stale_agent =
      match Coord.read_json config agent_file |> Types.agent_of_yojson with
      | Ok agent ->
          { agent with status = Types.Busy; current_task = Some "task-001" }
      | Error msg -> Alcotest.fail ("agent parse failed: " ^ msg)
    in
    Coord.write_json config agent_file (Types.agent_to_yojson stale_agent);
    match Coord.claim_next_r config ~agent_name () with
    | Coord.Claim_next_no_unclaimed ->
        let agents = Coord.get_agents_raw config in
        let agent_after =
          List.find_opt (fun (agent : Types.agent) ->
            String.equal agent.name agent_name) agents
        in
        (match agent_after with
        | Some agent ->
            Alcotest.(check (option string))
              "stale current_task cleared" None agent.current_task;
            Alcotest.(check string)
              "status reset to active" "active"
              (Types.agent_status_to_string agent.status)
        | None -> Alcotest.fail "agent missing after reconcile")
    | _ -> Alcotest.fail "expected no_unclaimed after stale reconcile"
  )

(* ============================================================ *)
(* BUG-004: claim_next auto-release Tests                        *)
(* ============================================================ *)

(** BUG-004: Same agent calling claim_next twice should auto-release
    the first task, not orphan it. *)
let test_claim_next_auto_releases_previous () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"First" ~priority:1 ~description:"" in
    let _ = Coord.add_task config ~title:"Second" ~priority:2 ~description:"" in

    (* First claim: agent gets task-001 *)
    let r1 = Coord.claim_next config ~agent_name:"claude" in
    Alcotest.(check bool) "first claim ok" true (contains_check r1);
    Alcotest.(check bool) "first claim has task-001" true (str_contains r1 "task-001");

    (* Second claim by same agent: should auto-release task-001, claim task-002 *)
    let r2 = Coord.claim_next config ~agent_name:"claude" in
    (* Result should contain warning about auto-release *)
    Alcotest.(check bool) "second claim contains warning" true (contains_warning r2);
    Alcotest.(check bool) "mentions released task" true (str_contains r2 "task-001");
    Alcotest.(check bool) "claims new task" true (str_contains r2 "task-002");

    (* Verify task-001 is back to Todo (not orphaned) via raw task data *)
    let tasks = Coord.get_tasks_raw config in
    let task_001 = List.find_opt (fun (t : Types.task) -> t.id = "task-001") tasks in
    (match task_001 with
     | Some t ->
         Alcotest.(check string) "task-001 released to todo"
           "todo" (Types.task_status_to_string t.task_status)
     | None -> Alcotest.fail "task-001 not found in backlog")
  )

(** BUG-004: After auto-release, the released task is claimable by others. *)
let test_claim_next_released_task_claimable_by_others () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Task A" ~priority:1 ~description:"" in
    let _ = Coord.add_task config ~title:"Task B" ~priority:2 ~description:"" in

    (* Claude claims task-001 *)
    let _ = Coord.claim_next config ~agent_name:"claude" in
    (* Claude claims again, auto-releasing task-001 *)
    let _ = Coord.claim_next config ~agent_name:"claude" in

    (* Gemini should be able to claim the released task-001 *)
    let r = Coord.claim_next config ~agent_name:"gemini" in
    Alcotest.(check bool) "gemini can claim released task" true (contains_check r);
    Alcotest.(check bool) "gemini gets task-001" true (str_contains r "task-001")
  )

(** BUG-004: claim_next_r returns released_task_id in structured result. *)
let test_claim_next_r_released_task_field () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Alpha" ~priority:1 ~description:"" in
    let _ = Coord.add_task config ~title:"Beta" ~priority:2 ~description:"" in

    (* First claim: no previous task to release *)
    let r1 = Coord.claim_next_r config ~agent_name:"claude" () in
    (match r1 with
     | Coord.Claim_next_claimed { released_task_id = None; task_id; _ } ->
         Alcotest.(check string) "first claim is task-001" "task-001" task_id
     | Coord.Claim_next_claimed { released_task_id = Some _; _ } ->
         Alcotest.fail "first claim should not release anything"
     | _ -> Alcotest.fail "first claim should succeed");

    (* Second claim: should release task-001 *)
    let r2 = Coord.claim_next_r config ~agent_name:"claude" () in
    (match r2 with
     | Coord.Claim_next_claimed { released_task_id = Some rid; task_id; _ } ->
         Alcotest.(check string) "released task-001" "task-001" rid;
         Alcotest.(check string) "claimed task-002" "task-002" task_id
     | Coord.Claim_next_claimed { released_task_id = None; _ } ->
         Alcotest.fail "second claim should report released task"
     | _ -> Alcotest.fail "second claim should succeed")
  )

let test_release_hard_stop_blocks_future_claim_next () =
  with_test_env (fun config ->
    let claude = find_agent_name_by_prefix config "claude" in
    let _ = Coord.add_task config ~title:"Phantom task" ~priority:1 ~description:"" in
    let _ = Coord.add_task config ~title:"Healthy task" ~priority:2 ~description:"" in
    let _ = Coord.claim_task config ~agent_name:claude ~task_id:"task-001" in
    let handoff_context : Types.task_handoff_context =
      {
        summary = "PR #6561 not found - do not reclaim";
        reason = Some "phantom artifact";
        next_step = Some "cancel the stale task";
        failure_mode = Some "not_found";
        evidence_refs = [ "PR#6561" ];
        updated_at = None;
        updated_by = Some claude;
      }
    in
    (match
       Coord.release_task_r config ~agent_name:claude ~task_id:"task-001"
         ~handoff_context ()
     with
    | Ok _ -> ()
    | Error e -> Alcotest.fail (Types.masc_error_to_string e));
    let task_001 =
      match
        List.find_opt
          (fun (t : Types.task) -> String.equal t.id "task-001")
          (Coord.get_tasks_raw config)
      with
      | Some task -> task
      | None -> Alcotest.fail "task-001 not found after release"
    in
    Alcotest.(check string) "task-001 back to todo" "todo"
      (Types.task_status_to_string task_001.task_status);
    Alcotest.(check int) "release increments cycle count" 1 task_001.cycle_count;
    Alcotest.(check (option string)) "hard-stop reason persisted"
      (Some "PR #6561 not found - do not reclaim")
      task_001.do_not_reclaim_reason;
    match Coord.claim_next_r config ~agent_name:claude () with
    | Coord.Claim_next_claimed { task_id; _ } ->
        Alcotest.(check string) "claim_next skips blocked todo" "task-002" task_id
    | _ -> Alcotest.fail "expected claim_next_r to skip blocked task-001")

let test_release_hard_stop_blocks_direct_reclaim () =
  with_test_env (fun config ->
    let claude = find_agent_name_by_prefix config "claude" in
    let _ = Coord.add_task config ~title:"Phantom task" ~priority:1 ~description:"" in
    let _ = Coord.claim_task config ~agent_name:claude ~task_id:"task-001" in
    let handoff_context : Types.task_handoff_context =
      {
        summary = "PR #6561 not found - do not reclaim";
        reason = Some "phantom artifact";
        next_step = Some "cancel the stale task";
        failure_mode = Some "not_found";
        evidence_refs = [ "PR#6561" ];
        updated_at = None;
        updated_by = Some claude;
      }
    in
    (match
       Coord.release_task_r config ~agent_name:claude ~task_id:"task-001"
         ~handoff_context ()
     with
    | Ok _ -> ()
    | Error e -> Alcotest.fail (Types.masc_error_to_string e));
    match Coord.claim_task_r config ~agent_name:claude ~task_id:"task-001" () with
    | Error (Types.TaskInvalidState message) ->
        Alcotest.(check bool) "direct claim blocked by do_not_reclaim_reason" true
          (str_contains message "blocked from re-claim")
    | Error e ->
        Alcotest.fail
          ("expected TaskInvalidState, got " ^ Types.masc_error_to_string e)
    | Ok _ -> Alcotest.fail "direct claim should be blocked after hard-stop release")

(* ============================================================ *)
(* Update Priority Tests                                         *)
(* ============================================================ *)

let test_update_priority () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:5 ~description:"" in
    let result = Coord.update_priority config ~task_id:"task-001" ~priority:1 in
    Alcotest.(check bool) "priority updated" true (contains_check result);
    Alcotest.(check bool) "shows old and new" true
      (str_contains result "P5" && str_contains result "P1")
  )

let test_update_priority_nonexistent () =
  with_test_env (fun config ->
    let result = Coord.update_priority config ~task_id:"task-999" ~priority:1 in
    Alcotest.(check bool) "task not found" true (contains_error result)
  )

let test_update_priority_negative () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:5 ~description:"" in
    let result = Coord.update_priority config ~task_id:"task-001" ~priority:(-1) in
    Alcotest.(check bool) "negative priority allowed" true (contains_check result)
  )

(* ============================================================ *)
(* Cancel Task Tests                                             *)
(* ============================================================ *)

let test_cancel_task_todo () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let result = Coord.cancel_task_r config ~agent_name:"claude" ~task_id:"task-001" ~reason:"Not needed" in
    match result with
    | Ok msg -> Alcotest.(check bool) "cancel success" true (str_contains msg "cancelled")
    | Error _ -> Alcotest.fail "Expected Ok"
  )

let test_cancel_task_claimed_by_self () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Coord.claim_task config ~agent_name:"claude" ~task_id:"task-001" in

    let result = Coord.cancel_task_r config ~agent_name:"claude" ~task_id:"task-001" ~reason:"Changed plans" in
    match result with
    | Ok msg -> Alcotest.(check bool) "cancel own task" true (str_contains msg "cancelled")
    | Error _ -> Alcotest.fail "Expected Ok"
  )

let test_cancel_task_claimed_by_other () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Coord.claim_task config ~agent_name:"gemini" ~task_id:"task-001" in

    let result = Coord.cancel_task_r config ~agent_name:"claude" ~task_id:"task-001" ~reason:"" in
    match result with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "Expected Error"
  )

let test_cancel_task_nonexistent () =
  with_test_env (fun config ->
    let result = Coord.cancel_task_r config ~agent_name:"claude" ~task_id:"task-999" ~reason:"" in
    match result with
    | Error Types.TaskNotFound _ -> ()
    | _ -> Alcotest.fail "Expected TaskNotFound"
  )

let test_cancel_done_task () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Coord.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let _ = transition_done config ~agent_name:"claude" ~task_id:"task-001" ~notes:"" in

    let result = Coord.cancel_task_r config ~agent_name:"claude" ~task_id:"task-001" ~reason:"" in
    match result with
    | Error Types.TaskInvalidState _ -> ()
    | _ -> Alcotest.fail "Expected TaskInvalidState"
  )

(* ============================================================ *)
(* Transition Task Tests                                         *)
(* ============================================================ *)

let test_transition_claim () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let result = Coord.transition_task_r config ~agent_name:"claude" ~task_id:"task-001" ~action:Types.Claim () in
    match result with
    | Ok msg -> Alcotest.(check bool) "claim via transition" true (str_contains msg "todo" && str_contains msg "claimed")
    | Error _ -> Alcotest.fail "Expected Ok"
  )

let test_transition_start () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Coord.claim_task config ~agent_name:"claude" ~task_id:"task-001" in

    let result = Coord.transition_task_r config ~agent_name:"claude" ~task_id:"task-001" ~action:Types.Start () in
    match result with
    | Ok msg -> Alcotest.(check bool) "start via transition" true (str_contains msg "in_progress")
    | Error _ -> Alcotest.fail "Expected Ok"
  )

let test_transition_release () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Coord.claim_task config ~agent_name:"claude" ~task_id:"task-001" in

    let result = Coord.release_task_r config ~agent_name:"claude" ~task_id:"task-001" () in
    match result with
    | Ok msg -> Alcotest.(check bool) "release via transition" true (str_contains msg "todo")
    | Error _ -> Alcotest.fail "Expected Ok"
  )

let test_transition_release_todo_noop () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in

    let result = Coord.release_task_r config ~agent_name:"claude" ~task_id:"task-001" () in
    match result with
    | Ok msg ->
        Alcotest.(check bool) "release todo no-op" true
          (str_contains msg "already todo")
    | Error _ -> Alcotest.fail "Expected Ok no-op"
  )

let test_transition_invalid () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in
    (* Try to start without claiming first *)
    let result = Coord.transition_task_r config ~agent_name:"claude" ~task_id:"task-001" ~action:Types.Start () in
    match result with
    | Error Types.TaskInvalidState _ -> ()
    | _ -> Alcotest.fail "Expected TaskInvalidState"
  )

let test_transition_version_mismatch () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in

    (* Pass wrong expected version *)
    let result = Coord.transition_task_r config ~agent_name:"claude" ~task_id:"task-001"
                   ~action:Types.Claim ~expected_version:999 () in
    match result with
    | Error Types.TaskInvalidState _ -> ()
    | _ -> Alcotest.fail "Expected TaskInvalidState for version mismatch"
  )

let test_transition_done_idempotent () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Coord.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let _ = Coord.transition_task_r config ~agent_name:"claude" ~task_id:"task-001" ~action:Types.Done_action () in
    (* Second done call should succeed as no-op *)
    let result = Coord.transition_task_r config ~agent_name:"claude" ~task_id:"task-001" ~action:Types.Done_action () in
    match result with
    | Ok msg -> Alcotest.(check bool) "done idempotent" true (str_contains msg "no-op")
    | Error e -> Alcotest.failf "Expected Ok (no-op), got error: %s" (Types.masc_error_to_string e)
  )

let test_transition_cancel_idempotent () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in
    (* Cancel from Todo (allowed) *)
    let _ = Coord.transition_task_r config ~agent_name:"claude" ~task_id:"task-001" ~action:Types.Cancel () in
    (* Second cancel call should succeed as no-op *)
    let result = Coord.transition_task_r config ~agent_name:"claude" ~task_id:"task-001" ~action:Types.Cancel () in
    match result with
    | Ok msg -> Alcotest.(check bool) "cancel idempotent" true (str_contains msg "no-op")
    | Error e -> Alcotest.failf "Expected Ok (no-op), got error: %s" (Types.masc_error_to_string e)
  )

(* ============================================================ *)
(* Observability Tests                                           *)
(* ============================================================ *)

let test_join_leave_emit_observability () =
  with_test_env (fun config ->
    let before_seq = latest_ring_seq () in
    let join_result =
      Coord.join config ~agent_name:"gemini" ~capabilities:[ "review" ] ()
    in
    Alcotest.(check bool) "join succeeds" true (contains_check join_result);
    let gemini = find_agent_name_by_prefix config "gemini" in
    let leave_result = Coord.leave config ~agent_name:gemini in
    Alcotest.(check bool) "leave succeeds" true (contains_check leave_result);

    let audit_entries = Audit_log.read_entries ~n:50 config in
    Alcotest.(check bool) "audit join recorded" true
      (audit_has_entry audit_entries ~agent_id:gemini
         ~action_pred:(function Audit_log.Join -> true | _ -> false)
         ~details:
           [
             ("event_family", "agent_lifecycle");
             ("event_kind", "join");
           ]);
    Alcotest.(check bool) "audit leave recorded" true
      (audit_has_entry audit_entries ~agent_id:gemini
         ~action_pred:(function Audit_log.Leave -> true | _ -> false)
         ~details:
           [
             ("event_family", "agent_lifecycle");
             ("event_kind", "leave");
           ]);

    let telemetry_events = Telemetry_eio.read_all_events config in
    let has_joined =
      List.exists
        (fun (entry : Telemetry_eio.event_record) ->
          match entry.event with
          | Telemetry_eio.Agent_joined { agent_id; _ } ->
              String.equal agent_id gemini
          | _ -> false)
        telemetry_events
    in
    let has_left =
      List.exists
        (fun (entry : Telemetry_eio.event_record) ->
          match entry.event with
          | Telemetry_eio.Agent_left { agent_id; reason } ->
              String.equal agent_id gemini && String.equal reason "leave"
          | _ -> false)
        telemetry_events
    in
    Alcotest.(check bool) "telemetry join recorded" true has_joined;
    Alcotest.(check bool) "telemetry leave recorded" true has_left;

    let ring_entries =
      Log.Ring.recent ~limit:50 ~module_filter:"Coord" ~since_seq:before_seq ()
    in
    Alcotest.(check bool) "ring join recorded" true
      (ring_has_entry ring_entries
         ~details:
           [
             ("event_family", "agent_lifecycle");
             ("event_kind", "join");
             ("agent_id", gemini);
           ]);
    Alcotest.(check bool) "ring leave recorded" true
      (ring_has_entry ring_entries
         ~details:
           [
             ("event_family", "agent_lifecycle");
             ("event_kind", "leave");
             ("agent_id", gemini);
           ]))

let test_task_transitions_emit_observability () =
  with_test_env (fun config ->
    let before_seq = latest_ring_seq () in
    let claude = find_agent_name_by_prefix config "claude" in
    let _ = Coord.add_task config ~title:"Observed Task" ~priority:1 ~description:"" in

    (match Coord.claim_task_r config ~agent_name:claude ~task_id:"task-001" () with
    | Ok _ -> ()
    | Error err ->
        Alcotest.failf "claim_task_r failed: %s"
          (Types.show_masc_error err));
    (match
       Coord.transition_task_r config ~agent_name:claude ~task_id:"task-001"
         ~action:Types.Start ()
     with
    | Ok _ -> ()
    | Error err ->
        Alcotest.failf "transition_task_r start failed: %s"
          (Types.show_masc_error err));
    (match
       transition_done_r config ~agent_name:claude ~task_id:"task-001"
         ~notes:"done" with
    | Ok _ -> ()
    | Error err ->
        Alcotest.failf "transition_task_r done failed: %s"
          (Types.show_masc_error err));

    let audit_entries = Audit_log.read_entries ~n:50 config in
    Alcotest.(check bool) "audit claim recorded" true
      (audit_has_entry audit_entries ~agent_id:claude
         ~action_pred:(function Audit_log.ClaimTask -> true | _ -> false)
         ~details:
           [
             ("event_family", "task_transition");
             ("transition", "claim");
             ("task_id", "task-001");
           ]);
    Alcotest.(check bool) "audit start recorded" true
      (audit_has_entry audit_entries ~agent_id:claude
         ~action_pred:(function Audit_log.StartTask -> true | _ -> false)
         ~details:
           [
             ("event_family", "task_transition");
             ("transition", "start");
             ("task_id", "task-001");
           ]);
    Alcotest.(check bool) "audit done recorded" true
      (audit_has_entry audit_entries ~agent_id:claude
         ~action_pred:(function Audit_log.DoneTask -> true | _ -> false)
         ~details:
           [
             ("event_family", "task_transition");
             ("transition", "done");
             ("task_id", "task-001");
           ]);

    let telemetry_events = Telemetry_eio.read_all_events config in
    let has_started =
      List.exists
        (fun (entry : Telemetry_eio.event_record) ->
          match entry.event with
          | Telemetry_eio.Task_started { task_id; agent_id } ->
              String.equal task_id "task-001" && String.equal agent_id claude
          | _ -> false)
        telemetry_events
    in
    let has_completed =
      List.exists
        (fun (entry : Telemetry_eio.event_record) ->
          match entry.event with
          | Telemetry_eio.Task_completed { task_id; success; _ } ->
              String.equal task_id "task-001" && success
          | _ -> false)
        telemetry_events
    in
    Alcotest.(check bool) "telemetry start recorded" true has_started;
    Alcotest.(check bool) "telemetry completion recorded" true has_completed;

    let ring_entries =
      Log.Ring.recent ~limit:50 ~module_filter:"Task" ~since_seq:before_seq ()
    in
    Alcotest.(check bool) "ring claim recorded" true
      (ring_has_entry ring_entries
         ~details:
           [
             ("event_family", "task_transition");
             ("transition", "claim");
             ("task_id", "task-001");
           ]);
    Alcotest.(check bool) "ring start recorded" true
      (ring_has_entry ring_entries
         ~details:
           [
             ("event_family", "task_transition");
             ("transition", "start");
             ("task_id", "task-001");
           ]);
    Alcotest.(check bool) "ring done recorded" true
      (ring_has_entry ring_entries
         ~details:
           [
             ("event_family", "task_transition");
             ("transition", "done");
             ("task_id", "task-001");
           ]))

let test_transition_done_from_claimed_emits_observability () =
  with_test_env (fun config ->
    let before_seq = latest_ring_seq () in
    let claude = find_agent_name_by_prefix config "claude" in
    let _ = Coord.add_task config ~title:"Claimed Done Task" ~priority:1 ~description:"" in
    let claim_result = Coord.claim_task config ~agent_name:claude ~task_id:"task-001" in
    Alcotest.(check bool) "claim succeeds" true
      (contains_check claim_result);
    let done_result =
      transition_done config ~agent_name:claude ~task_id:"task-001"
        ~notes:"claim-to-done path"
    in
    Alcotest.(check bool) "claimed done succeeds" true
      (contains_check done_result);

    let audit_entries = Audit_log.read_entries ~n:50 config in
    Alcotest.(check bool) "claimed done audit recorded" true
      (audit_has_entry audit_entries ~agent_id:claude
         ~action_pred:(function Audit_log.DoneTask -> true | _ -> false)
         ~details:
           [
             ("event_family", "task_transition");
             ("transition", "done");
             ("task_id", "task-001");
           ]);

    let telemetry_events = Telemetry_eio.read_all_events config in
    let has_completed =
      List.exists
        (fun (entry : Telemetry_eio.event_record) ->
          match entry.event with
          | Telemetry_eio.Task_completed { task_id; success; _ } ->
              String.equal task_id "task-001" && success
          | _ -> false)
        telemetry_events
    in
    Alcotest.(check bool) "claimed done telemetry completion recorded" true
      has_completed;

    let ring_entries =
      Log.Ring.recent ~limit:50 ~module_filter:"Task" ~since_seq:before_seq ()
    in
    Alcotest.(check bool) "claimed done ring done recorded" true
      (ring_has_entry ring_entries
         ~details:
           [
             ("event_family", "task_transition");
             ("transition", "done");
             ("task_id", "task-001");
           ]))

let test_claim_next_auto_release_emits_release_observability () =
  with_test_env (fun config ->
    let before_seq = latest_ring_seq () in
    let claude = find_agent_name_by_prefix config "claude" in
    let _ = Coord.add_task config ~title:"First" ~priority:1 ~description:"" in
    let _ = Coord.add_task config ~title:"Second" ~priority:2 ~description:"" in

    (match Coord.claim_next_r config ~agent_name:claude () with
    | Coord.Claim_next_claimed _ -> ()
    | _ -> Alcotest.fail "expected first claim_next_r to succeed");
    (match Coord.claim_next_r config ~agent_name:claude () with
    | Coord.Claim_next_claimed { released_task_id = Some released; task_id; _ } ->
        Alcotest.(check string) "released task id" "task-001" released;
        Alcotest.(check string) "new task id" "task-002" task_id
    | _ -> Alcotest.fail "expected auto-release on second claim_next_r");

    let audit_entries = Audit_log.read_entries ~n:50 config in
    Alcotest.(check bool) "audit release recorded" true
      (audit_has_entry audit_entries ~agent_id:claude
         ~action_pred:(function Audit_log.ReleaseTask -> true | _ -> false)
         ~details:
           [
             ("event_family", "task_transition");
             ("transition", "release");
             ("task_id", "task-001");
           ]);

    let ring_entries =
      Log.Ring.recent ~limit:50 ~module_filter:"Task" ~since_seq:before_seq ()
    in
    Alcotest.(check bool) "ring release recorded" true
      (ring_has_entry ring_entries
         ~details:
           [
             ("event_family", "task_transition");
             ("transition", "release");
             ("task_id", "task-001");
           ]))

(* ============================================================ *)
(* Pause/Resume Tests                                            *)
(* ============================================================ *)

let test_pause_room () =
  with_test_env (fun config ->
    Coord.pause config ~by:"claude" ~reason:"Testing pause";
    Alcotest.(check bool) "room is paused" true (Coord.is_paused config)
  )

let test_resume_room () =
  with_test_env (fun config ->
    Coord.pause config ~by:"claude" ~reason:"Testing pause";
    let result = Coord.resume config ~by:"claude" in
    match result with
    | `Resumed ->
        Alcotest.(check bool) "room resumed" true (not (Coord.is_paused config))
    | _ -> Alcotest.fail "Expected Resumed"
  )

let test_resume_not_paused () =
  with_test_env (fun config ->
    let result = Coord.resume config ~by:"claude" in
    match result with
    | `Already_running -> ()
    | _ -> Alcotest.fail "Expected Already_running"
  )

let test_pause_info () =
  with_test_env (fun config ->
    Coord.pause config ~by:"claude" ~reason:"Maintenance";
    match Coord.pause_info config with
    | Some (Some by, Some reason, Some _) ->
        Alcotest.(check string) "paused by" "claude" by;
        Alcotest.(check string) "reason" "Maintenance" reason
    | _ -> Alcotest.fail "Expected pause info"
  )

let test_pause_info_not_paused () =
  with_test_env (fun config ->
    match Coord.pause_info config with
    | None -> ()
    | Some _ -> Alcotest.fail "Expected None"
  )

(* ============================================================ *)
(* Raw Data Accessor Tests                                       *)
(* ============================================================ *)

let test_get_tasks_raw () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Task 1" ~priority:1 ~description:"" in
    let _ = Coord.add_task config ~title:"Task 2" ~priority:2 ~description:"" in

    let tasks = Coord.get_tasks_raw config in
    Alcotest.(check int) "two tasks" 2 (List.length tasks)
  )

let test_get_tasks_raw_empty () =
  with_test_env (fun config ->
    let tasks = Coord.get_tasks_raw config in
    Alcotest.(check int) "no tasks" 0 (List.length tasks)
  )

let test_get_agents_raw () =
  with_test_env (fun config ->
    let _ = Coord.join config ~agent_name:"gemini" ~capabilities:["test"] () in

    let agents : Types.agent list = Coord.get_agents_raw config in
    (* claude from init + gemini *)
    Alcotest.(check bool) "at least 2 agents" true (List.length agents >= 2)
  )

let test_get_messages_raw () =
  with_test_env (fun config ->
    let _ = Coord.broadcast config ~from_agent:"claude" ~content:"Message 1" in
    let _ = Coord.broadcast config ~from_agent:"claude" ~content:"Message 2" in

    let msgs = Coord.get_messages_raw config ~since_seq:0 ~limit:10 in
    Alcotest.(check bool) "has messages" true (List.length msgs >= 2)
  )

let test_is_agent_joined () =
  with_test_env (fun config ->
    (* claude is joined from init *)
    (* Note: agent names are auto-generated with nicknames, so we check by type prefix *)
    let agents : Types.agent list = Coord.get_agents_raw config in
    let has_agent = List.exists (fun (a : Types.agent) ->
      String.length a.name >= 6 && String.sub a.name 0 6 = "claude"
    ) agents in
    Alcotest.(check bool) "claude is joined" true has_agent
  )

(* ============================================================ *)
(* Done Transition Result Variant Tests                          *)
(* ============================================================ *)

let test_transition_done_r_success () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Coord.claim_task config ~agent_name:"claude" ~task_id:"task-001" in

    let result = transition_done_r config ~agent_name:"claude" ~task_id:"task-001" ~notes:"Done!" in
    match result with
    | Ok msg -> Alcotest.(check bool) "done success" true (contains_check msg)
    | Error _ -> Alcotest.fail "Expected Ok"
  )

let test_transition_done_r_not_claimed () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in

    let result = transition_done_r config ~agent_name:"claude" ~task_id:"task-001" ~notes:"" in
    match result with
    | Error (Types.TaskInvalidState msg) ->
        Alcotest.(check bool) "mentions todo state" true (str_contains msg "todo")
    | _ -> Alcotest.fail "Expected TaskInvalidState"
  )

let test_transition_done_r_not_found () =
  with_test_env (fun config ->
    let result = transition_done_r config ~agent_name:"claude" ~task_id:"task-999" ~notes:"" in
    match result with
    | Error Types.TaskNotFound _ -> ()
    | _ -> Alcotest.fail "Expected TaskNotFound"
  )

let test_claim_task_r_success () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in

    let result = Coord.claim_task_r config ~agent_name:"claude" ~task_id:"task-001" () in
    match result with
    | Ok msg -> Alcotest.(check bool) "claim success" true (str_contains msg "claimed")
    | Error _ -> Alcotest.fail "Expected Ok"
  )

let test_claim_task_r_already_claimed () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Coord.claim_task config ~agent_name:"gemini" ~task_id:"task-001" in

    let result = Coord.claim_task_r config ~agent_name:"claude" ~task_id:"task-001" () in
    match result with
    | Error Types.TaskAlreadyClaimed _ -> ()
    | _ -> Alcotest.fail "Expected TaskAlreadyClaimed"
  )

(* ============================================================ *)
(* GC (Garbage Collection) Tests                                 *)
(* ============================================================ *)

let test_gc_no_cleanup_needed () =
  with_test_env (fun config ->
    let result = Coord.gc config () in
    Alcotest.(check bool) "gc result has content" true (String.length result > 0);
    Alcotest.(check bool) "no zombie cleanup" true (str_contains result "No zombie")
  )

let test_gc_with_tasks () =
  with_test_env (fun config ->
    let _ = Coord.add_task config ~title:"Recent Task" ~priority:1 ~description:"" in
    let result = Coord.gc config ~days:1 () in
    Alcotest.(check bool) "gc with recent task" true (String.length result > 0)
  )

(* ============================================================ *)
(* Task ID Parsing Tests                                         *)
(* ============================================================ *)

let test_task_id_to_int_valid () =
  match Coord.task_id_to_int "task-001" with
  | Some 1 -> ()
  | _ -> Alcotest.fail "Expected Some 1"

let test_task_id_to_int_large () =
  match Coord.task_id_to_int "task-999" with
  | Some 999 -> ()
  | _ -> Alcotest.fail "Expected Some 999"

let test_task_id_to_int_invalid_prefix () =
  match Coord.task_id_to_int "issue-001" with
  | None -> ()
  | Some _ -> Alcotest.fail "Expected None"

let test_task_id_to_int_empty () =
  match Coord.task_id_to_int "" with
  | None -> ()
  | Some _ -> Alcotest.fail "Expected None"

let test_task_id_to_int_only_prefix () =
  match Coord.task_id_to_int "task-" with
  | None -> ()
  | Some _ -> Alcotest.fail "Expected None"

(* ============================================================ *)
(* Update Agent Tests                                            *)
(* ============================================================ *)

let test_update_agent_status () =
  with_test_env (fun config ->
    let _ = Coord.join config ~agent_name:"gemini" ~capabilities:["test"] () in

    (* Get the actual agent name (auto-generated nickname) *)
    let agents = Coord.get_agents_raw config in
    let gemini = List.find_opt (fun (a : Types.agent) ->
      String.length a.name >= 6 && String.sub a.name 0 6 = "gemini"
    ) agents in
    match gemini with
    | Some agent ->
        let result = Coord.update_agent_r config ~agent_name:agent.name ~status:"listening" () in
        (match result with
         | Ok _ -> ()
         | Error _ -> Alcotest.fail "Expected Ok")
    | None -> Alcotest.fail "Gemini agent not found"
  )

let test_update_agent_capabilities () =
  with_test_env (fun config ->
    let _ = Coord.join config ~agent_name:"gemini" ~capabilities:[] () in

    let agents = Coord.get_agents_raw config in
    let gemini = List.find_opt (fun (a : Types.agent) ->
      String.length a.name >= 6 && String.sub a.name 0 6 = "gemini"
    ) agents in
    match gemini with
    | Some agent ->
        let result = Coord.update_agent_r config ~agent_name:agent.name
                       ~capabilities:["python"; "code-review"] () in
        (match result with
         | Ok _ -> ()
         | Error _ -> Alcotest.fail "Expected Ok")
    | None -> Alcotest.fail "Gemini agent not found"
  )

let test_update_agent_not_found () =
  with_test_env (fun config ->
    let result = Coord.update_agent_r config ~agent_name:"nonexistent" ~status:"active" () in
    match result with
    | Error Types.AgentNotFound _ -> ()
    | _ -> Alcotest.fail "Expected AgentNotFound"
  )

(* ============================================================ *)
(* Archive Task Tests                                            *)
(* ============================================================ *)

let test_append_archive_tasks () =
  with_test_env (fun config ->
    let task : Types.task = {
      id = "task-test";
      title = "Archive Test";
      description = "Test description";
      goal_id = None;
      task_status = Types.Done {
        assignee = "claude";
        completed_at = "2026-01-01T00:00:00Z";
        notes = None;
      };
      priority = 1;
      files = [];
      created_at = "2026-01-01T00:00:00Z";
      worktree = None;
      created_by = None;
      stage = None;
      contract = None; handoff_context = None; cycle_count = 0; do_not_reclaim_reason = None;
    } in
    Coord.append_archive_tasks config [task];

    (* Add a new task to verify archive max ID is checked *)
    let result = Coord.add_task config ~title:"New Task" ~priority:1 ~description:"" in
    Alcotest.(check bool) "task added" true (contains_check result)
  )

(* ============================================================ *)
(* Test Runner                                                   *)
(* ============================================================ *)

let () =
  Random.init 42;
  Alcotest.run "Coord Coverage" [
    (* === Batch Operations === *)
    "batch", [
      Alcotest.test_case "add tasks" `Quick test_batch_add_tasks;
      Alcotest.test_case "empty list" `Quick test_batch_add_empty_list;
      Alcotest.test_case "single task" `Quick test_batch_add_single_task;
      Alcotest.test_case "preserves priorities" `Quick test_batch_add_preserves_priorities;
    ];

    (* === Claim Next === *)
    "claim_next", [
      Alcotest.test_case "basic" `Quick test_claim_next_basic;
      Alcotest.test_case "priority order" `Quick test_claim_next_priority_order;
      Alcotest.test_case "empty backlog" `Quick test_claim_next_empty_backlog;
      Alcotest.test_case "all claimed" `Quick test_claim_next_all_claimed;
      Alcotest.test_case "skips done/cancelled" `Quick
        test_claim_next_skips_done_and_cancelled;
      Alcotest.test_case "terminal-only backlog" `Quick
        test_claim_next_terminal_only_backlog;
      Alcotest.test_case "consecutive" `Quick test_claim_next_consecutive;
      Alcotest.test_case "reconciles stale current_task" `Quick
        test_claim_next_reconciles_stale_agent_current_task;
      Alcotest.test_case "BUG-004: auto-releases previous" `Quick test_claim_next_auto_releases_previous;
      Alcotest.test_case "BUG-004: released task claimable" `Quick test_claim_next_released_task_claimable_by_others;
      Alcotest.test_case "BUG-004: released_task_id field" `Quick test_claim_next_r_released_task_field;
      Alcotest.test_case "release hard-stop blocks future claim_next" `Quick
        test_release_hard_stop_blocks_future_claim_next;
      Alcotest.test_case "release hard-stop blocks direct reclaim" `Quick
        test_release_hard_stop_blocks_direct_reclaim;
    ];

    (* === Update Priority === *)
    "update_priority", [
      Alcotest.test_case "basic" `Quick test_update_priority;
      Alcotest.test_case "nonexistent" `Quick test_update_priority_nonexistent;
      Alcotest.test_case "negative" `Quick test_update_priority_negative;
    ];

    (* === Cancel Task === *)
    "cancel", [
      Alcotest.test_case "todo task" `Quick test_cancel_task_todo;
      Alcotest.test_case "claimed by self" `Quick test_cancel_task_claimed_by_self;
      Alcotest.test_case "claimed by other" `Quick test_cancel_task_claimed_by_other;
      Alcotest.test_case "nonexistent" `Quick test_cancel_task_nonexistent;
      Alcotest.test_case "done task" `Quick test_cancel_done_task;
    ];

    (* === Transition Task === *)
    "transition", [
      Alcotest.test_case "claim" `Quick test_transition_claim;
      Alcotest.test_case "start" `Quick test_transition_start;
      Alcotest.test_case "release" `Quick test_transition_release;
      Alcotest.test_case "release todo no-op" `Quick
        test_transition_release_todo_noop;
      Alcotest.test_case "invalid" `Quick test_transition_invalid;
      Alcotest.test_case "version mismatch" `Quick test_transition_version_mismatch;
      Alcotest.test_case "done idempotent" `Quick test_transition_done_idempotent;
      Alcotest.test_case "cancel idempotent" `Quick test_transition_cancel_idempotent;
    ];

    (* === Observability === *)
    "observability", [
      Alcotest.test_case "join leave fan-out" `Quick
        test_join_leave_emit_observability;
      Alcotest.test_case "task transitions fan-out" `Quick
        test_task_transitions_emit_observability;
      Alcotest.test_case "claimed done fan-out" `Quick
        test_transition_done_from_claimed_emits_observability;
      Alcotest.test_case "claim_next auto-release fan-out" `Quick
        test_claim_next_auto_release_emits_release_observability;
    ];

    (* === Pause/Resume === *)
    "pause_resume", [
      Alcotest.test_case "pause" `Quick test_pause_room;
      Alcotest.test_case "resume" `Quick test_resume_room;
      Alcotest.test_case "resume not paused" `Quick test_resume_not_paused;
      Alcotest.test_case "pause info" `Quick test_pause_info;
      Alcotest.test_case "pause info not paused" `Quick test_pause_info_not_paused;
    ];

    (* === Raw Data Accessors === *)
    "raw_data", [
      Alcotest.test_case "get tasks raw" `Quick test_get_tasks_raw;
      Alcotest.test_case "get tasks raw empty" `Quick test_get_tasks_raw_empty;
      Alcotest.test_case "get agents raw" `Quick test_get_agents_raw;
      Alcotest.test_case "get messages raw" `Quick test_get_messages_raw;
      Alcotest.test_case "is agent joined" `Quick test_is_agent_joined;
    ];

    (* === Result Variants === *)
    "result_variants", [
      Alcotest.test_case "transition done success" `Quick
        test_transition_done_r_success;
      Alcotest.test_case "transition done not claimed" `Quick
        test_transition_done_r_not_claimed;
      Alcotest.test_case "transition done not found" `Quick
        test_transition_done_r_not_found;
      Alcotest.test_case "claim_task_r success" `Quick test_claim_task_r_success;
      Alcotest.test_case "claim_task_r already claimed" `Quick test_claim_task_r_already_claimed;
    ];

    (* === GC === *)
    "gc", [
      Alcotest.test_case "no cleanup" `Quick test_gc_no_cleanup_needed;
      Alcotest.test_case "with tasks" `Quick test_gc_with_tasks;
    ];

    (* === Task ID Parsing === *)
    "task_id", [
      Alcotest.test_case "valid" `Quick test_task_id_to_int_valid;
      Alcotest.test_case "large" `Quick test_task_id_to_int_large;
      Alcotest.test_case "invalid prefix" `Quick test_task_id_to_int_invalid_prefix;
      Alcotest.test_case "empty" `Quick test_task_id_to_int_empty;
      Alcotest.test_case "only prefix" `Quick test_task_id_to_int_only_prefix;
    ];

    (* === Update Agent === *)
    "update_agent", [
      Alcotest.test_case "status" `Quick test_update_agent_status;
      Alcotest.test_case "capabilities" `Quick test_update_agent_capabilities;
      Alcotest.test_case "not found" `Quick test_update_agent_not_found;
    ];

    (* === Archive === *)
    "archive", [
      Alcotest.test_case "append tasks" `Quick test_append_archive_tasks;
    ];
  ]
