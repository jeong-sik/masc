module Types = Masc_domain

(** Comprehensive coverage tests for Workspace module

    Target: 35+ additional tests covering:
    - Batch operations
    - Task transitions (claim_next, update_priority, cancel, release)
    - Pause/Resume functionality
    - GC and cleanup
    - Result-returning variants (_r functions)
    - Raw data accessors
    - Edge cases not covered in test_workspace.ml
*)

open Masc
(* Economy moved to the masc_agent_economy leaf lib (wrapped false);
   the bare module resolves via masc_test_deps, no mega-lib alias needed. *)

let () = Workspace_metric_hooks.install ()

let () = Mirage_crypto_rng_unix.use_default ()
let () = Workspace_metric_hooks.install ()

(* ============================================================ *)
(* Test Helpers                                                  *)
(* ============================================================ *)

(** Check for success emoji *)
let contains_check result =
  String.length result >= 3 && String.sub result 0 3 = "\xE2\x9C\x85" (* ✅ *)
;;

(** Check for warning emoji *)
let contains_warning result =
  String.length result >= 3 && String.sub result 0 3 = "\xE2\x9A\xA0" (* ⚠ *)
;;

(** Check for error emoji *)
let contains_error result =
  String.length result >= 3 && String.sub result 0 3 = "\xE2\x9D\x8C" (* ❌ *)
;;

(** Check for cancel emoji *)
let _contains_cancel result =
  String.length result >= 4 && String.sub result 0 4 = "\xF0\x9F\x9A\xAB" (* 🚫 *)
;;

(** Substring check helper *)
let str_contains s substring =
  let len_s = String.length s in
  let len_sub = String.length substring in
  if len_sub > len_s
  then false
  else (
    let rec check i =
      if i > len_s - len_sub
      then false
      else if String.sub s i len_sub = substring
      then true
      else check (i + 1)
    in
    check 0)
;;

(** Legacy string APIs are gradually moving away from emoji-prefixed messages.
    Treat a non-empty message without known problem text as success. *)
let starts_with s prefix =
  let len_s = String.length s in
  let len_prefix = String.length prefix in
  len_s >= len_prefix && String.sub s 0 len_prefix = prefix

let contains_any haystack needles =
  List.exists (str_contains haystack) needles

let has_legacy_result_prefix prefix result = starts_with result prefix

let contains_problem_result result =
  let lower = String.lowercase_ascii result in
  has_legacy_result_prefix "\xE2\x9D\x8C" result
  || contains_any lower
       [ "error:"
       ; "[taskerror]"
       ; "[agenterror]"
       ; "[systemerror]"
       ; "not found"
       ; "notfound"
       ; "not initialized"
       ; "notinitialized"
       ; "not joined"
       ; "notjoined"
       ; "invalid"
       ; "invalidstate"
       ; "empty"
       ; "too long"
       ; "blocked"
       ; "already claimed"
       ; "cannot"
       ; "rejected"
       ; "was not in the namespace"
       ; "requires"
       ]

(** Check for semantic success across legacy string result formats. *)
let contains_check result =
  has_legacy_result_prefix "\xE2\x9C\x85" result
  || (String.trim result <> "" && not (contains_problem_result result))

(** Check for warning/problem result across legacy string result formats. *)
let contains_warning result =
  has_legacy_result_prefix "\xE2\x9A\xA0" result || contains_problem_result result

(** Check for semantic error across legacy string result formats. *)
let contains_error = contains_problem_result

(** Check for cancel emoji *)
let _contains_cancel result =
  String.length result >= 4 && String.sub result 0 4 = "\xF0\x9F\x9A\xAB"  (* 🚫 *)

(** Create fresh test environment with cleanup.
    Wrapped in Eio_main.run because Workspace.init uses Eio.Mutex internally. *)
let with_test_env f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc_coverage_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir tmp_dir 0o755;
  let config = Workspace.default_config tmp_dir in
  let _ = Workspace.init config ~agent_name:(Some "claude") in
  try
    f config;
    let _ = Workspace.reset config in
    Unix.rmdir tmp_dir
  with
  | e ->
    let _ = Workspace.reset config in
    Unix.rmdir tmp_dir;
    raise e
;;

let with_env key value f =
  let prev = Sys.getenv_opt key in
  Unix.putenv key value;
  let result =
    try f () with
    | e ->
      (match prev with
       | Some v -> Unix.putenv key v
       | None -> Unix.putenv key "");
      raise e
  in
  (match prev with
   | Some v -> Unix.putenv key v
   | None -> Unix.putenv key "");
  result
;;

let with_task_economy_enabled f =
  Economy.reset_cache ();
  with_env "MASC_ECONOMY_ENABLED" "true" (fun () ->
    with_env "MASC_ECONOMY_INITIAL_BALANCE" "5.0" (fun () ->
      with_env "MASC_ECONOMY_REWARD_TASK_DONE" "10.0" (fun () ->
        with_env "MASC_ECONOMY_REPUTATION_MULTIPLIER" "false" (fun () ->
          Fun.protect ~finally:Economy.reset_cache f))))
;;

let latest_ring_seq () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> entry.seq
  | [] -> 0
;;

let detail_string details key =
  match details with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) -> Some value
     | _ -> None)
  | _ -> None
;;

let detail_matches details expected =
  List.for_all
    (fun (key, value) ->
       match detail_string details key with
       | Some actual -> String.equal actual value
       | None -> false)
    expected
;;

let find_agent_name_by_prefix config prefix =
  match
    List.find_opt
      (fun (agent : Masc_domain.agent) -> String.starts_with ~prefix agent.name)
      (Workspace.get_agents_raw config)
  with
  | Some agent -> agent.name
  | None -> Alcotest.failf "agent with prefix %s not found" prefix
;;

let transition_done_r config ~agent_name ~task_id ~notes =
  Workspace.transition_task_r
    config
    ~agent_name
    ~task_id
    ~action:Masc_domain.Done_action
    ~notes
    ()
;;

let transition_done config ~agent_name ~task_id ~notes =
  match transition_done_r config ~agent_name ~task_id ~notes with
  | Ok msg -> msg
  | Error err -> Masc_domain.masc_error_to_string err
;;

let audit_has_entry entries ~agent_id ~action_pred ~details =
  List.exists
    (fun (entry : Audit_log.audit_entry) ->
       String.equal entry.agent_id agent_id
       && action_pred entry.action
       && detail_matches entry.details details)
    entries
;;

let ring_has_entry entries ~details =
  List.exists
    (fun (entry : Log.Ring.entry) -> detail_matches entry.details details)
    entries
;;

(* ============================================================ *)
(* Batch Operations Tests                                        *)
(* ============================================================ *)

let test_batch_add_tasks () =
  with_test_env (fun config ->
    let tasks =
      [ "Task A", 1, "Description A", None
      ; "Task B", 2, "Description B", None
      ; "Task C", 3, "Description C", None
      ]
    in
    let result = Workspace.batch_add_tasks config tasks in
    Alcotest.(check bool) "batch add success" true (contains_check result);
    Alcotest.(check bool) "contains task-001" true (str_contains result "task-001");
    Alcotest.(check bool) "contains task-003" true (str_contains result "task-003"))
;;

let test_batch_add_empty_list () =
  with_test_env (fun config ->
    let result = Workspace.batch_add_tasks config [] in
    Alcotest.(check bool)
      "batch add empty returns something"
      true
      (String.length result > 0))
;;

let test_batch_add_single_task () =
  with_test_env (fun config ->
    let result = Workspace.batch_add_tasks config [ "Single", 1, "Only one", None ] in
    Alcotest.(check bool) "single task batch" true (contains_check result))
;;

let test_batch_add_preserves_priorities () =
  with_test_env (fun config ->
    let tasks = [ "High Priority", 1, "", None; "Low Priority", 5, "", None ] in
    let _ = Workspace.batch_add_tasks config tasks in
    let task_list = Workspace.list_tasks config in
    Alcotest.(check bool)
      "shows priorities"
      true
      (str_contains task_list "[1]" && str_contains task_list "[5]"))
;;

(* ============================================================ *)
(* Claim Next Tests                                              *)
(* ============================================================ *)

let test_claim_next_basic () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test Task" ~priority:1 ~description:"" in
    let result = Workspace.claim_next config ~agent_name:"claude" in
    Alcotest.(check bool) "claim next success" true (contains_check result);
    Alcotest.(check bool) "has task id" true (str_contains result "task-001"))
;;

let test_claim_next_priority_order () =
  with_test_env (fun config ->
    (* Add tasks in non-priority order *)
    let _ = Workspace.add_task config ~title:"Low" ~priority:5 ~description:"" in
    let _ = Workspace.add_task config ~title:"High" ~priority:1 ~description:"" in
    let _ = Workspace.add_task config ~title:"Medium" ~priority:3 ~description:"" in
    (* Should claim highest priority (lowest number) first *)
    let result = Workspace.claim_next config ~agent_name:"claude" in
    Alcotest.(check bool)
      "claims high priority first"
      true
      (str_contains result "[P1]" || str_contains result "task-002"))
;;

let test_claim_next_empty_backlog () =
  with_test_env (fun config ->
    let result = Workspace.claim_next config ~agent_name:"claude" in
    Alcotest.(check bool) "no tasks message" true (str_contains result "No unclaimed"))
;;

let test_claim_next_all_claimed () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Only Task" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"gemini" ~task_id:"task-001" in
    let result = Workspace.claim_next config ~agent_name:"claude" in
    Alcotest.(check bool) "no unclaimed tasks" true (str_contains result "No unclaimed"))
;;

let test_claim_next_skips_done_and_cancelled () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Done Task" ~priority:1 ~description:"" in
    let _ = Workspace.add_task config ~title:"Cancelled Task" ~priority:2 ~description:"" in
    let _ = Workspace.add_task config ~title:"Todo Task" ~priority:3 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"alice" ~task_id:"task-001" in
    let _ =
      transition_done config ~agent_name:"alice" ~task_id:"task-001" ~notes:"done"
    in
    (match
       Workspace.cancel_task_r
         config
         ~agent_name:"alice"
         ~task_id:"task-002"
         ~reason:"cancelled"
     with
    | Ok _ -> ()
    | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e));
    let result = Workspace.claim_next config ~agent_name:"claude" in
    Alcotest.(check bool)
      "claims the remaining todo task"
      true
      (str_contains result "task-003");
    let tasks = Workspace.get_tasks_raw config in
    let status_of task_id =
      match
        List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id) tasks
      with
      | Some task -> Masc_domain.task_status_to_string task.task_status
      | None -> Alcotest.failf "missing task %s" task_id
    in
    Alcotest.(check string) "done task preserved" "done" (status_of "task-001");
    Alcotest.(check string) "cancelled task preserved" "cancelled" (status_of "task-002");
    Alcotest.(check string) "todo task claimed" "claimed" (status_of "task-003"))
;;

let test_claim_next_terminal_only_backlog () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Done Task" ~priority:1 ~description:"" in
    let _ = Workspace.add_task config ~title:"Cancelled Task" ~priority:2 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"alice" ~task_id:"task-001" in
    let _ =
      transition_done config ~agent_name:"alice" ~task_id:"task-001" ~notes:"done"
    in
    (match
       Workspace.cancel_task_r
         config
         ~agent_name:"alice"
         ~task_id:"task-002"
         ~reason:"cancelled"
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e));
    let result = Workspace.claim_next config ~agent_name:"claude" in
    Alcotest.(check bool)
      "terminal backlog reports no unclaimed tasks"
      true
      (str_contains result "No unclaimed"))
;;

let test_claim_next_consecutive () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"First" ~priority:1 ~description:"" in
    let _ = Workspace.add_task config ~title:"Second" ~priority:2 ~description:"" in
    let r1 = Workspace.claim_next config ~agent_name:"claude" in
    let r2 = Workspace.claim_next config ~agent_name:"gemini" in
    Alcotest.(check bool) "first claim success" true (contains_check r1);
    Alcotest.(check bool) "second claim success" true (contains_check r2);
    (* Different agents should get different tasks *)
    Alcotest.(check bool)
      "different tasks"
      true
      (str_contains r1 "task-001" || str_contains r2 "task-002"))
;;

let test_claim_next_reconciles_stale_agent_current_task () =
  with_test_env (fun config ->
    let agent_name =
      match Workspace.get_agents_raw config with
      | [ agent ] -> agent.Masc_domain.name
      | _ -> Alcotest.fail "expected exactly one bound agent"
    in
    let _ = Workspace.add_task config ~title:"Cancelled already" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name ~task_id:"task-001" in
    (match
       Workspace.cancel_task_r
         config
         ~agent_name
         ~task_id:"task-001"
         ~reason:"terminal stale-cache fixture"
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e));
    let agent_file =
      Filename.concat (Workspace.agents_dir config) (Workspace.safe_filename agent_name ^ ".json")
    in
    let stale_agent =
      match Workspace.read_json config agent_file |> Masc_domain.agent_of_yojson with
      | Ok agent ->
        { agent with status = Masc_domain.Busy; current_task = Some "task-001" }
      | Error msg -> Alcotest.fail ("agent parse failed: " ^ msg)
    in
    Workspace.write_json config agent_file (Masc_domain.agent_to_yojson stale_agent);
    match Workspace.claim_next_r config ~agent_name () with
    | Workspace.Claim_next_no_unclaimed ->
      let agents = Workspace.get_agents_raw config in
      let agent_after =
        List.find_opt
          (fun (agent : Masc_domain.agent) -> String.equal agent.name agent_name)
          agents
      in
      (match agent_after with
       | Some agent ->
         Alcotest.(check (option string))
           "stale current_task cleared"
           None
           agent.current_task;
         Alcotest.(check string)
           "status reset to active"
           "active"
           (Masc_domain.agent_status_to_string agent.status)
       | None -> Alcotest.fail "agent missing after reconcile")
    | _ -> Alcotest.fail "expected no_unclaimed after stale reconcile")
;;

let test_status_hides_stale_agent_current_task_without_writing () =
  with_env "MASC_VERIFICATION_FSM_ENABLED" "true" (fun () ->
    with_test_env (fun config ->
      let agent_name =
        match Workspace.get_agents_raw config with
        | [ agent ] -> agent.Masc_domain.name
        | _ -> Alcotest.fail "expected exactly one bound agent"
      in
      let _ =
        Workspace.add_task config ~title:"Awaiting verifier" ~priority:1 ~description:""
      in
      let _ = Workspace.claim_task config ~agent_name ~task_id:"task-001" in
      (match
         Workspace.transition_task_r
           config
           ~agent_name
           ~task_id:"task-001"
           ~action:Masc_domain.Submit_for_verification
           ~notes:"verification setup notes"
           ()
       with
       | Ok _ -> ()
       | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e));
      let agent_file =
        Filename.concat
          (Workspace.agents_dir config)
          (Workspace.safe_filename agent_name ^ ".json")
      in
      let stale_agent =
        match Workspace.read_json config agent_file |> Masc_domain.agent_of_yojson with
        | Ok agent ->
          { agent with status = Masc_domain.Busy; current_task = Some "task-001" }
        | Error msg -> Alcotest.fail ("agent parse failed: " ^ msg)
      in
      Workspace.write_json config agent_file (Masc_domain.agent_to_yojson stale_agent);
      let output = Workspace.status config in
      Alcotest.(check bool)
        "status renders stale task as idle"
        true
        (str_contains output (Printf.sprintf "%s → idle" agent_name));
      let agent_after =
        match Workspace.read_json config agent_file |> Masc_domain.agent_of_yojson with
        | Ok agent -> agent
        | Error msg -> Alcotest.fail ("agent parse failed after status: " ^ msg)
      in
      Alcotest.(check (option string))
        "status read does not clear stale current_task"
        (Some "task-001")
        agent_after.current_task;
      Alcotest.(check string)
        "status read does not reset stored status"
        "busy"
        (Masc_domain.agent_status_to_string agent_after.status)))
;;

(* ============================================================ *)
(* #10421: claim_next existing-task preservation                 *)
(* ============================================================ *)

(** Same agent calling claim_next twice should keep the current task bound.
    Implicit release creates keeper hot-potato loops when a model repeats the
    claim tool before doing the work. *)
let test_claim_next_preserves_existing_task () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"First" ~priority:1 ~description:"" in
    let _ = Workspace.add_task config ~title:"Second" ~priority:2 ~description:"" in
    let r1 = Workspace.claim_next config ~agent_name:"claude" in
    Alcotest.(check bool) "first claim has task-001" true (str_contains r1 "task-001");
    let r2 = Workspace.claim_next config ~agent_name:"claude" in
    Alcotest.(check bool)
      "second claim keeps current task"
      true
      (str_contains r2 "already holds");
    Alcotest.(check bool)
      "second claim mentions task-001"
      true
      (str_contains r2 "task-001");
    Alcotest.(check bool)
      "second claim does not move to task-002"
      false
      (str_contains r2 "task-002");
    let tasks = Workspace.get_tasks_raw config in
    let task_001 =
      List.find_opt (fun (t : Masc_domain.task) -> t.id = "task-001") tasks
    in
    let task_002 =
      List.find_opt (fun (t : Masc_domain.task) -> t.id = "task-002") tasks
    in
    (match task_001 with
     | Some t ->
       Alcotest.(check string)
         "task-001 stays claimed"
         "claimed"
         (Masc_domain.task_status_to_string t.task_status)
     | None -> Alcotest.fail "task-001 not found in backlog");
    match task_002 with
    | Some t ->
      Alcotest.(check string)
        "task-002 stays todo"
        "todo"
        (Masc_domain.task_status_to_string t.task_status)
    | None -> Alcotest.fail "task-002 not found in backlog")
;;

(** A repeated claim by the owner must not make the current task claimable by
    other agents. Peers should move to the next Todo task. *)
let test_claim_next_preserved_task_not_claimable_by_others () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Task A" ~priority:1 ~description:"" in
    let _ = Workspace.add_task config ~title:"Task B" ~priority:2 ~description:"" in
    let _ = Workspace.claim_next config ~agent_name:"claude" in
    let _ = Workspace.claim_next config ~agent_name:"claude" in
    let r = Workspace.claim_next config ~agent_name:"gemini" in
    Alcotest.(check bool)
      "gemini does not get preserved task"
      false
      (str_contains r "task-001");
    Alcotest.(check bool) "gemini gets task-002" true (str_contains r "task-002"))
;;

(** claim_next_r keeps the legacy released_task_id field but no longer sets it
    for repeated owner calls. *)
let test_claim_next_r_preserved_task_field () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Alpha" ~priority:1 ~description:"" in
    let _ = Workspace.add_task config ~title:"Beta" ~priority:2 ~description:"" in
    let r1 = Workspace.claim_next_r config ~agent_name:"claude" () in
    (match r1 with
     | Workspace.Claim_next_claimed { released_task_id = None; task_id; _ } ->
       Alcotest.(check string) "first claim is task-001" "task-001" task_id
     | Workspace.Claim_next_claimed { released_task_id = Some _; _ } ->
       Alcotest.fail "first claim should not release anything"
     | _ -> Alcotest.fail "first claim should succeed");
    let r2 = Workspace.claim_next_r config ~agent_name:"claude" () in
    match r2 with
    | Workspace.Claim_next_claimed { released_task_id = None; task_id; message; _ } ->
      Alcotest.(check string) "still task-001" "task-001" task_id;
      Alcotest.(check bool)
        "message says already holds"
        true
        (str_contains message "already holds")
    | Workspace.Claim_next_claimed { released_task_id = Some _; _ } ->
      Alcotest.fail "second claim should not report a released task"
    | _ -> Alcotest.fail "second claim should succeed")
;;

let test_release_hard_stop_blocks_future_claim_next () =
  with_test_env (fun config ->
    let claude = find_agent_name_by_prefix config "claude" in
    let _ = Workspace.add_task config ~title:"Phantom task" ~priority:1 ~description:"" in
    let _ = Workspace.add_task config ~title:"Healthy task" ~priority:2 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:claude ~task_id:"task-001" in
    let handoff_context : Masc_domain.task_handoff_context =
      { summary = "PR #6561 belongs to a completed upstream scope"
      ; reason = Some "phantom artifact"
      ; next_step = Some "cancel the stale task"
      ; failure_mode = Some "not_found"
      ; reclaim_policy = Some Masc_domain.Block_reclaim
      ; evidence_refs = [ "PR#6561" ]
      ; updated_at = None
      ; updated_by = Some claude
      }
    in
    (match
       Workspace.release_task_r
         config
         ~agent_name:claude
         ~task_id:"task-001"
         ~handoff_context
         ()
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e));
    let task_001 =
      match
        List.find_opt
          (fun (t : Masc_domain.task) -> String.equal t.id "task-001")
          (Workspace.get_tasks_raw config)
      with
      | Some task -> task
      | None -> Alcotest.fail "task-001 not found after release"
    in
    Alcotest.(check string)
      "task-001 back to todo"
      "todo"
      (Masc_domain.task_status_to_string task_001.task_status);
    Alcotest.(check int) "release increments cycle count" 1 task_001.cycle_count;
    Alcotest.(check (option string))
      "hard-stop reason persisted"
      (Some "PR #6561 belongs to a completed upstream scope")
      task_001.do_not_reclaim_reason;
    Alcotest.(check (option string))
      "typed hard-stop persisted"
      (Some "block_reclaim")
      (Option.map Masc_domain.task_reclaim_policy_to_string task_001.reclaim_policy);
    match Workspace.claim_next_r config ~agent_name:claude () with
    | Workspace.Claim_next_claimed { task_id; _ } ->
      Alcotest.(check string) "claim_next skips blocked todo" "task-002" task_id
    | _ -> Alcotest.fail "expected claim_next_r to skip blocked task-001")
;;

let test_release_hard_stop_blocks_direct_reclaim () =
  with_test_env (fun config ->
    let claude = find_agent_name_by_prefix config "claude" in
    let _ = Workspace.add_task config ~title:"Phantom task" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:claude ~task_id:"task-001" in
    let handoff_context : Masc_domain.task_handoff_context =
      { summary = "PR #6561 belongs to a completed upstream scope"
      ; reason = Some "phantom artifact"
      ; next_step = Some "cancel the stale task"
      ; failure_mode = Some "not_found"
      ; reclaim_policy = Some Masc_domain.Block_reclaim
      ; evidence_refs = [ "PR#6561" ]
      ; updated_at = None
      ; updated_by = Some claude
      }
    in
    (match
       Workspace.release_task_r
         config
         ~agent_name:claude
         ~task_id:"task-001"
         ~handoff_context
         ()
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e));
    match Workspace.claim_task_r config ~agent_name:claude ~task_id:"task-001" () with
    | Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState message)) ->
      Alcotest.(check bool)
        "direct claim blocked by typed reclaim_policy"
        true
        (str_contains message "blocked from re-claim")
    | Error e ->
      Alcotest.fail
        ("expected TaskInvalidState, got " ^ Masc_domain.masc_error_to_string e)
    | Ok _ -> Alcotest.fail "direct claim should be blocked after hard-stop release")
;;

let write_tasks config tasks =
  let backlog = Workspace.read_backlog config in
  let updated : Masc_domain.backlog =
    { tasks; last_updated = Masc_domain.now_iso (); version = backlog.version + 1 }
  in
  Workspace.write_backlog config updated
;;

let task_by_id config task_id =
  match
    List.find_opt
      (fun (t : Masc_domain.task) -> String.equal t.id task_id)
      (Workspace.get_tasks_raw config)
  with
  | Some task -> task
  | None -> Alcotest.failf "%s not found" task_id
;;

let update_task config task_id f =
  let backlog = Workspace.read_backlog config in
  let tasks =
    List.map
      (fun (t : Masc_domain.task) ->
         if String.equal t.id task_id then f t else t)
      backlog.tasks
  in
  write_tasks config tasks
;;

let assert_claimed_by config task_id agent_name =
  let task = task_by_id config task_id in
  match task.task_status with
  | Masc_domain.Claimed { assignee; _ } ->
    Alcotest.(check string) "claimed assignee" agent_name assignee
  | status ->
    Alcotest.failf
      "expected %s to be claimed, got %s"
      task_id
      (Masc_domain.task_status_to_string status)
;;

let done_status assignee =
  Masc_domain.Done
    { assignee; completed_at = Masc_domain.now_iso (); notes = Some "completed" }
;;

let test_claim_next_reclaims_done_allow_reclaim () =
  with_test_env (fun config ->
    let claude = find_agent_name_by_prefix config "claude" in
    let _ =
      Workspace.add_task config ~title:"Completed coordination task" ~priority:1 ~description:""
    in
    update_task config "task-001" (fun (t : Masc_domain.task) ->
      { t with
        task_status = done_status "prior-agent"
      ; reclaim_policy = Some Masc_domain.Allow_reclaim
      });
    match Workspace.claim_next_r config ~agent_name:claude () with
    | Workspace.Claim_next_claimed { task_id; _ } ->
      Alcotest.(check string) "completed task claimed" "task-001" task_id;
      assert_claimed_by config "task-001" claude;
      let task = task_by_id config "task-001" in
      Alcotest.(check (option string))
        "allow_reclaim policy cleared"
        None
        (Option.map Masc_domain.task_reclaim_policy_to_string task.reclaim_policy)
    | Workspace.Claim_next_no_eligible _ ->
      Alcotest.fail "completed Allow_reclaim task should be eligible"
    | Workspace.Claim_next_no_unclaimed ->
      Alcotest.fail "completed Allow_reclaim task should not be treated as absent"
    | Workspace.Claim_next_error msg -> Alcotest.fail msg)
;;

let test_claim_next_blocks_done_block_reclaim () =
  with_test_env (fun config ->
    let claude = find_agent_name_by_prefix config "claude" in
    let _ =
      Workspace.add_task config ~title:"Completed blocked task" ~priority:1 ~description:""
    in
    update_task config "task-001" (fun (t : Masc_domain.task) ->
      { t with
        task_status = done_status "prior-agent"
      ; reclaim_policy = Some Masc_domain.Block_reclaim
      ; do_not_reclaim_reason = Some "completed upstream scope"
      });
    match Workspace.claim_next_r config ~agent_name:claude () with
    | Workspace.Claim_next_no_eligible { blocked_count; _ } ->
      Alcotest.(check int) "blocked completed task counted" 1 blocked_count;
      let task = task_by_id config "task-001" in
      Alcotest.(check string)
        "blocked completed task preserved"
        "done"
        (Masc_domain.task_status_to_string task.task_status)
    | Workspace.Claim_next_claimed { task_id; _ } ->
      Alcotest.failf "Block_reclaim completed task must not be claimed, got %s" task_id
    | Workspace.Claim_next_no_unclaimed ->
      Alcotest.fail "Block_reclaim completed task should be reported as blocked"
    | Workspace.Claim_next_error msg -> Alcotest.fail msg)
;;

let test_claim_next_ignores_legacy_auto_cycle_text () =
  with_test_env (fun config ->
    let claude = find_agent_name_by_prefix config "claude" in
    let _ =
      Workspace.add_task config ~title:"Legacy soft-blocked task" ~priority:1 ~description:""
    in
    let backlog = Workspace.read_backlog config in
    let tasks =
      List.map
        (fun (t : Masc_domain.task) ->
           if String.equal t.id "task-001"
           then
             { t with cycle_count = 3; do_not_reclaim_reason = Some "auto: 3 releases" }
           else t)
        backlog.tasks
    in
    write_tasks config tasks;
    match Workspace.claim_next_r config ~agent_name:claude () with
    | Workspace.Claim_next_claimed { task_id; _ } ->
      Alcotest.(check string) "legacy text does not block claim" "task-001" task_id;
      let task = task_by_id config task_id in
      Alcotest.(check (option string))
        "legacy text cleared after claim"
        None
        task.do_not_reclaim_reason
    | Workspace.Claim_next_no_eligible _ ->
      Alcotest.fail "legacy auto-cycle text should be claimable"
    | Workspace.Claim_next_no_unclaimed ->
      Alcotest.fail "expected one claimable task"
    | Workspace.Claim_next_error msg -> Alcotest.fail msg)
;;

let test_claim_next_ignores_routing_handoff_text () =
  with_test_env (fun config ->
    let claude = find_agent_name_by_prefix config "claude" in
    let _ =
      Workspace.add_task config ~title:"Rerouted coding task" ~priority:1 ~description:""
    in
    let _ =
      Workspace.add_task config ~title:"Normal lower-priority work" ~priority:5 ~description:""
    in
    let backlog = Workspace.read_backlog config in
    let tasks =
      List.map
        (fun (t : Masc_domain.task) ->
           if String.equal t.id "task-001"
           then
             { t with
               cycle_count = 1
             ; do_not_reclaim_reason =
                 Some
                   "Auto-claimed by sandbox-isolated keeper with no \
                    access to masc source. Releasing for keeper with repo access."
             }
           else t)
        backlog.tasks
    in
    write_tasks config tasks;
    match Workspace.claim_next_r config ~agent_name:claude () with
    | Workspace.Claim_next_claimed { task_id; _ } ->
      Alcotest.(check string) "free-text routing handoff remains claimable" "task-001" task_id
    | Workspace.Claim_next_no_eligible _ ->
      Alcotest.fail "normal unblocked task should remain claimable"
    | Workspace.Claim_next_no_unclaimed ->
      Alcotest.fail "expected normal unblocked task"
    | Workspace.Claim_next_error msg -> Alcotest.fail msg)
;;

let test_claim_next_does_not_deprioritize_legacy_text () =
  with_test_env (fun config ->
    let claude = find_agent_name_by_prefix config "claude" in
    let _ =
      Workspace.add_task
        config
        ~title:"Legacy soft-blocked urgent"
        ~priority:1
        ~description:""
    in
    let _ =
      Workspace.add_task
        config
        ~title:"Normal lower-priority work"
        ~priority:5
        ~description:""
    in
    let backlog = Workspace.read_backlog config in
    let tasks =
      List.map
        (fun (t : Masc_domain.task) ->
           if String.equal t.id "task-001"
           then
             { t with cycle_count = 3; do_not_reclaim_reason = Some "auto: 3 releases" }
           else t)
        backlog.tasks
    in
    write_tasks config tasks;
    match Workspace.claim_next_r config ~agent_name:claude () with
    | Workspace.Claim_next_claimed { task_id; _ } ->
      Alcotest.(check string) "priority still wins despite legacy text" "task-001" task_id
    | Workspace.Claim_next_no_eligible _ ->
      Alcotest.fail "normal unblocked task should be claimed before fallback"
    | Workspace.Claim_next_no_unclaimed -> Alcotest.fail "expected claimable tasks"
    | Workspace.Claim_next_error msg -> Alcotest.fail msg)
;;

let test_release_cycles_do_not_create_auto_do_not_reclaim () =
  with_test_env (fun config ->
    let claude = find_agent_name_by_prefix config "claude" in
    let _ = Workspace.add_task config ~title:"Retryable task" ~priority:1 ~description:"" in
    for _ = 1 to 3 do
      (match Workspace.claim_task_r config ~agent_name:claude ~task_id:"task-001" () with
       | Ok _ -> ()
       | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e));
      match Workspace.release_task_r config ~agent_name:claude ~task_id:"task-001" () with
      | Ok _ -> ()
      | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)
    done;
    let task = task_by_id config "task-001" in
    Alcotest.(check int) "release cycles still tracked" 3 task.cycle_count;
    Alcotest.(check (option string)) "no auto hard stop" None task.do_not_reclaim_reason;
    match Workspace.claim_task_r config ~agent_name:claude ~task_id:"task-001" () with
    | Ok _ -> ()
    | Error e ->
      Alcotest.fail
        ("retryable task should remain claimable: " ^ Masc_domain.masc_error_to_string e))
;;

let test_release_cycle_15_does_not_create_auto_hard_stop () =
  with_test_env (fun config ->
    let claude = find_agent_name_by_prefix config "claude" in
    let _ = Workspace.add_task config ~title:"Oscillating task" ~priority:1 ~description:"" in
    let backlog = Workspace.read_backlog config in
    let tasks =
      List.map
        (fun (t : Masc_domain.task) ->
           if String.equal t.id "task-001"
           then { t with cycle_count = 14; reclaim_policy = None; do_not_reclaim_reason = None }
           else t)
        backlog.tasks
    in
    write_tasks config tasks;
    (match Workspace.claim_task_r config ~agent_name:claude ~task_id:"task-001" () with
     | Ok _ -> ()
     | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e));
    (match Workspace.release_task_r config ~agent_name:claude ~task_id:"task-001" () with
     | Ok _ -> ()
     | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e));
    let task = task_by_id config "task-001" in
    Alcotest.(check int) "cycle count reaches former threshold" 15 task.cycle_count;
    Alcotest.(check (option string))
      "no auto typed hard-stop"
      None
      (Option.map Masc_domain.task_reclaim_policy_to_string task.reclaim_policy);
    Alcotest.(check (option string))
      "no auto hard-stop reason"
      None
      task.do_not_reclaim_reason;
    match Workspace.claim_task_r config ~agent_name:claude ~task_id:"task-001" () with
    | Ok _ -> ()
    | Error e ->
      Alcotest.fail
        ("cycle count alone should not block reclaim: " ^ Masc_domain.masc_error_to_string e))
;;

let test_claim_next_allows_failed_verification_repair () =
  with_test_env (fun config ->
    let claude = find_agent_name_by_prefix config "claude" in
    let _ =
      Workspace.add_task config ~title:"Repair rejected task" ~priority:1 ~description:""
    in
    let req =
      match
        Verification.create_request
          ~base_path:config.Workspace.base_path
          ~task_id:"task-001"
          ~output:(`Assoc [])
          ~criteria:[ Verification.Custom "tests pass" ]
          ~worker:"worker"
          ()
      with
      | Ok req -> req
      | Error msg -> Alcotest.fail ("create verification failed: " ^ msg)
    in
    (match
       Verification.submit_verdict
         ~base_path:config.Workspace.base_path
         ~req_id:req.id
         ~verifier:"verifier-agent"
         ~verdict:(Verification.Fail "missing evidence")
     with
     | Ok _ -> ()
     | Error msg -> Alcotest.fail ("submit verdict failed: " ^ msg));
    match Workspace.claim_next_r config ~agent_name:claude () with
    | Workspace.Claim_next_claimed { task_id; _ } ->
      Alcotest.(check string) "rejected task is repair-claimable" "task-001" task_id
    | Workspace.Claim_next_no_eligible _ ->
      Alcotest.fail "failed verification should not permanently block repair"
    | Workspace.Claim_next_no_unclaimed ->
      Alcotest.fail "expected failed verification task to remain in backlog"
    | Workspace.Claim_next_error msg -> Alcotest.fail msg)
;;

(* ============================================================ *)
(* Update Priority Tests                                         *)
(* ============================================================ *)

let test_update_priority () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:5 ~description:"" in
    let result = Workspace.update_priority config ~task_id:"task-001" ~priority:1 in
    Alcotest.(check bool) "priority updated" true (contains_check result);
    Alcotest.(check bool)
      "shows old and new"
      true
      (str_contains result "P5" && str_contains result "P1"))
;;

let test_update_priority_nonexistent () =
  with_test_env (fun config ->
    let result = Workspace.update_priority config ~task_id:"task-999" ~priority:1 in
    Alcotest.(check bool) "task not found" true (contains_error result))
;;

let test_update_priority_negative () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:5 ~description:"" in
    let result = Workspace.update_priority config ~task_id:"task-001" ~priority:(-1) in
    Alcotest.(check bool) "negative priority allowed" true (contains_check result))
;;

(* ============================================================ *)
(* Cancel Task Tests                                             *)
(* ============================================================ *)

let test_cancel_task_todo () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let result =
      Workspace.cancel_task_r
        config
        ~agent_name:"claude"
        ~task_id:"task-001"
        ~reason:"Not needed"
    in
    match result with
    | Ok msg -> Alcotest.(check bool) "cancel success" true (str_contains msg "cancelled")
    | Error _ -> Alcotest.fail "Expected Ok")
;;

let test_cancel_task_claimed_by_self () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let result =
      Workspace.cancel_task_r
        config
        ~agent_name:"claude"
        ~task_id:"task-001"
        ~reason:"Changed plans"
    in
    match result with
    | Ok msg ->
      Alcotest.(check bool) "cancel own task" true (str_contains msg "cancelled")
    | Error _ -> Alcotest.fail "Expected Ok")
;;

let test_cancel_task_claimed_by_other () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"gemini" ~task_id:"task-001" in
    let result =
      Workspace.cancel_task_r config ~agent_name:"claude" ~task_id:"task-001" ~reason:""
    in
    match result with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "Expected Error")
;;

let test_cancel_task_nonexistent () =
  with_test_env (fun config ->
    let result =
      Workspace.cancel_task_r config ~agent_name:"claude" ~task_id:"task-999" ~reason:""
    in
    match result with
    | Error (Masc_domain.Task (Masc_domain.Task_error.NotFound _)) -> ()
    | _ -> Alcotest.fail "Expected TaskNotFound")
;;

let test_cancel_done_task () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let _ = transition_done config ~agent_name:"claude" ~task_id:"task-001" ~notes:"" in
    let result =
      Workspace.cancel_task_r config ~agent_name:"claude" ~task_id:"task-001" ~reason:""
    in
    match result with
    | Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState _)) -> ()
    | _ -> Alcotest.fail "Expected TaskInvalidState")
;;

(* ============================================================ *)
(* Transition Task Tests                                         *)
(* ============================================================ *)

let test_transition_claim () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let result =
      Workspace.transition_task_r
        config
        ~agent_name:"claude"
        ~task_id:"task-001"
        ~action:Masc_domain.Claim
        ()
    in
    match result with
    | Ok msg ->
      Alcotest.(check bool)
        "claim via transition"
        true
        (str_contains msg "todo" && str_contains msg "claimed")
    | Error _ -> Alcotest.fail "Expected Ok")
;;

let test_transition_start () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let result =
      Workspace.transition_task_r
        config
        ~agent_name:"claude"
        ~task_id:"task-001"
        ~action:Masc_domain.Start
        ()
    in
    match result with
    | Ok msg ->
      Alcotest.(check bool) "start via transition" true (str_contains msg "in_progress")
    | Error _ -> Alcotest.fail "Expected Ok")
;;

let test_transition_release () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let result =
      Workspace.release_task_r config ~agent_name:"claude" ~task_id:"task-001" ()
    in
    match result with
    | Ok msg ->
      Alcotest.(check bool) "release via transition" true (str_contains msg "todo")
    | Error _ -> Alcotest.fail "Expected Ok")
;;

let test_transition_release_keeper_transport_alias () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    match
      Workspace.release_task_r config ~agent_name:"keeper-claude-agent" ~task_id:"task-001" ()
    with
    | Ok msg ->
      Alcotest.(check bool)
        "release via keeper transport alias"
        true
        (str_contains msg "todo")
    | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e))
;;

let test_transition_release_generated_nickname_alias () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    match
      Workspace.release_task_r config ~agent_name:"claude-happy-shark" ~task_id:"task-001" ()
    with
    | Ok msg ->
      Alcotest.(check bool)
        "release via generated nickname alias"
        true
        (str_contains msg "todo")
    | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e))
;;

let test_transition_release_todo_noop () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let result =
      Workspace.release_task_r config ~agent_name:"claude" ~task_id:"task-001" ()
    in
    match result with
    | Ok msg ->
      Alcotest.(check bool) "release todo no-op" true (str_contains msg "already todo")
    | Error _ -> Alcotest.fail "Expected Ok no-op")
;;

let test_transition_invalid () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    (* Try to start without claiming first *)
    let result =
      Workspace.transition_task_r
        config
        ~agent_name:"claude"
        ~task_id:"task-001"
        ~action:Masc_domain.Start
        ()
    in
    match result with
    | Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState _)) -> ()
    | _ -> Alcotest.fail "Expected TaskInvalidState")
;;

let test_transition_submit_for_verification_requires_notes () =
  with_env "MASC_VERIFICATION_FSM_ENABLED" "true" (fun () ->
    with_test_env (fun config ->
      let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
      let _ = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
      let result =
        Workspace.transition_task_r
          config
          ~agent_name:"claude"
          ~task_id:"task-001"
          ~action:Masc_domain.Submit_for_verification
          ()
      in
      match result with
      | Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState msg)) ->
        Alcotest.(check bool)
          "empty notes rejected"
          true
          (str_contains msg "requires non-empty notes")
      | Ok _ -> Alcotest.fail "Expected empty notes rejection"
      | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)))
;;

let test_transition_version_mismatch () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    (* Pass wrong expected version *)
    let result =
      Workspace.transition_task_r
        config
        ~agent_name:"claude"
        ~task_id:"task-001"
        ~action:Masc_domain.Claim
        ~expected_version:999
        ()
    in
    match result with
    | Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState _)) -> ()
    | _ -> Alcotest.fail "Expected TaskInvalidState for version mismatch")
;;

let test_transition_done_idempotent () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let _ =
      Workspace.transition_task_r
        config
        ~agent_name:"claude"
        ~task_id:"task-001"
        ~action:Masc_domain.Done_action
        ()
    in
    (* Second done call should succeed as no-op *)
    let result =
      Workspace.transition_task_r
        config
        ~agent_name:"claude"
        ~task_id:"task-001"
        ~action:Masc_domain.Done_action
        ()
    in
    match result with
    | Ok msg -> Alcotest.(check bool) "done idempotent" true (str_contains msg "no-op")
    | Error e ->
      Alcotest.failf
        "Expected Ok (no-op), got error: %s"
        (Masc_domain.masc_error_to_string e))
;;

let test_transition_done_awards_task_reward_once () =
  with_task_economy_enabled (fun () ->
    with_test_env (fun config ->
      let claude = find_agent_name_by_prefix config "claude" in
      let _ = Workspace.add_task config ~title:"Rewarded task" ~priority:1 ~description:"" in
      let balance_before =
        Economy.get_balance ~base_path:config.base_path ~agent_name:claude
      in
      Alcotest.(check (float 0.01)) "initial balance" 5.0 balance_before;
      (match Workspace.claim_task_r config ~agent_name:claude ~task_id:"task-001" () with
       | Ok _ -> ()
       | Error err ->
         Alcotest.failf "claim_task_r failed: %s" (Masc_domain.show_masc_error err));
      (match
         Workspace.transition_task_r
           config
           ~agent_name:claude
           ~task_id:"task-001"
           ~action:Masc_domain.Start
           ()
       with
       | Ok _ -> ()
       | Error err ->
         Alcotest.failf
           "transition_task_r start failed: %s"
           (Masc_domain.show_masc_error err));
      (match
         transition_done_r config ~agent_name:claude ~task_id:"task-001" ~notes:"done"
       with
       | Ok _ -> ()
       | Error err ->
         Alcotest.failf
           "transition_task_r done failed: %s"
           (Masc_domain.show_masc_error err));
      let balance_after_done =
        Economy.get_balance ~base_path:config.base_path ~agent_name:claude
      in
      Alcotest.(check (float 0.01)) "done reward applied once" 15.0 balance_after_done;
      (match
         transition_done_r config ~agent_name:claude ~task_id:"task-001" ~notes:"repeat"
       with
       | Ok msg ->
         Alcotest.(check bool) "repeat done is no-op" true (str_contains msg "no-op")
       | Error err ->
         Alcotest.failf "repeat done failed: %s" (Masc_domain.show_masc_error err));
      let balance_after_repeat =
        Economy.get_balance ~base_path:config.base_path ~agent_name:claude
      in
      Alcotest.(check (float 0.01))
        "repeat done does not double pay"
        15.0
        balance_after_repeat))
;;

let test_transition_cancel_idempotent () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    (* Cancel from Todo (allowed) *)
    let _ =
      Workspace.transition_task_r
        config
        ~agent_name:"claude"
        ~task_id:"task-001"
        ~action:Masc_domain.Cancel
        ()
    in
    (* Second cancel call should succeed as no-op *)
    let result =
      Workspace.transition_task_r
        config
        ~agent_name:"claude"
        ~task_id:"task-001"
        ~action:Masc_domain.Cancel
        ()
    in
    match result with
    | Ok msg -> Alcotest.(check bool) "cancel idempotent" true (str_contains msg "no-op")
    | Error e ->
      Alcotest.failf
        "Expected Ok (no-op), got error: %s"
        (Masc_domain.masc_error_to_string e))
;;

(* ============================================================ *)
(* Observability Tests                                           *)
(* ============================================================ *)

let test_join_leave_emit_observability () =
  with_test_env (fun config ->
    let before_seq = latest_ring_seq () in
    let join_result =
      Workspace.bind_session config ~agent_name:"gemini" ~capabilities:[ "review" ] ()
    in
    Alcotest.(check bool) "join succeeds" true (contains_check join_result);
    let gemini = find_agent_name_by_prefix config "gemini" in
    let leave_result = Workspace.end_session config ~agent_name:gemini in
    Alcotest.(check bool) "leave succeeds" true (contains_check leave_result);
    let audit_entries = Audit_log.read_entries ~n:50 config in
    Alcotest.(check bool)
      "audit join recorded"
      true
      (audit_has_entry
         audit_entries
         ~agent_id:gemini
         ~action_pred:(function
           | Audit_log.Custom "agent_session_bound" -> true
           | _ -> false)
         ~details:[ "event_family", "agent_lifecycle"; "event_kind", "session_bound" ]);
    Alcotest.(check bool)
      "audit leave recorded"
      true
      (audit_has_entry
         audit_entries
         ~agent_id:gemini
         ~action_pred:(function
           | Audit_log.Custom "agent_session_ended" -> true
           | _ -> false)
         ~details:[ "event_family", "agent_lifecycle"; "event_kind", "session_ended" ]);
    let telemetry_events = Telemetry_eio.read_all_events config in
    let has_bound =
      List.exists
        (fun (entry : Telemetry_eio.event_record) ->
           match entry.event with
           | Telemetry_eio.Agent_session_bound { agent_id; _ } -> String.equal agent_id gemini
           | _ -> false)
        telemetry_events
    in
    let has_left =
      List.exists
        (fun (entry : Telemetry_eio.event_record) ->
           match entry.event with
           | Telemetry_eio.Agent_unbound { agent_id; reason } ->
             String.equal agent_id gemini && String.equal reason "session_ended"
           | _ -> false)
        telemetry_events
    in
    Alcotest.(check bool) "telemetry session bound recorded" true has_bound;
    Alcotest.(check bool) "telemetry leave recorded" true has_left;
    let ring_entries =
      Log.Ring.recent ~limit:50 ~module_filter:"Workspace" ~since_seq:before_seq ()
    in
    Alcotest.(check bool)
      "ring join recorded"
      true
      (ring_has_entry
         ring_entries
         ~details:
           [ "event_family", "agent_lifecycle"; "event_kind", "session_bound"; "agent_id", gemini ]);
    Alcotest.(check bool)
      "ring leave recorded"
      true
      (ring_has_entry
         ring_entries
         ~details:
           [ "event_family", "agent_lifecycle"
           ; "event_kind", "session_ended"
           ; "agent_id", gemini
           ]))
;;

let test_task_transitions_emit_observability () =
  with_test_env (fun config ->
    let before_seq = latest_ring_seq () in
    let claude = find_agent_name_by_prefix config "claude" in
    let _ = Workspace.add_task config ~title:"Observed Task" ~priority:1 ~description:"" in
    (match Workspace.claim_task_r config ~agent_name:claude ~task_id:"task-001" () with
     | Ok _ -> ()
     | Error err ->
       Alcotest.failf "claim_task_r failed: %s" (Masc_domain.show_masc_error err));
    (match
       Workspace.transition_task_r
         config
         ~agent_name:claude
         ~task_id:"task-001"
         ~action:Masc_domain.Start
         ()
     with
     | Ok _ -> ()
     | Error err ->
       Alcotest.failf
         "transition_task_r start failed: %s"
         (Masc_domain.show_masc_error err));
    (match
       transition_done_r config ~agent_name:claude ~task_id:"task-001" ~notes:"done"
     with
     | Ok _ -> ()
     | Error err ->
       Alcotest.failf
         "transition_task_r done failed: %s"
         (Masc_domain.show_masc_error err));
    let audit_entries = Audit_log.read_entries ~n:50 config in
    Alcotest.(check bool)
      "audit claim recorded"
      true
      (audit_has_entry
         audit_entries
         ~agent_id:claude
         ~action_pred:(function
           | Audit_log.ClaimTask -> true
           | _ -> false)
         ~details:
           [ "event_family", "task_transition"
           ; "transition", "claim"
           ; "task_id", "task-001"
           ]);
    Alcotest.(check bool)
      "audit start recorded"
      true
      (audit_has_entry
         audit_entries
         ~agent_id:claude
         ~action_pred:(function
           | Audit_log.StartTask -> true
           | _ -> false)
         ~details:
           [ "event_family", "task_transition"
           ; "transition", "start"
           ; "task_id", "task-001"
           ]);
    Alcotest.(check bool)
      "audit done recorded"
      true
      (audit_has_entry
         audit_entries
         ~agent_id:claude
         ~action_pred:(function
           | Audit_log.DoneTask -> true
           | _ -> false)
         ~details:
           [ "event_family", "task_transition"
           ; "transition", "done"
           ; "task_id", "task-001"
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
    Alcotest.(check bool)
      "ring claim recorded"
      true
      (ring_has_entry
         ring_entries
         ~details:
           [ "event_family", "task_transition"
           ; "transition", "claim"
           ; "task_id", "task-001"
           ]);
    Alcotest.(check bool)
      "ring start recorded"
      true
      (ring_has_entry
         ring_entries
         ~details:
           [ "event_family", "task_transition"
           ; "transition", "start"
           ; "task_id", "task-001"
           ]);
    Alcotest.(check bool)
      "ring done recorded"
      true
      (ring_has_entry
         ring_entries
         ~details:
           [ "event_family", "task_transition"
           ; "transition", "done"
           ; "task_id", "task-001"
           ]))
;;

let test_transition_done_from_claimed_emits_observability () =
  with_test_env (fun config ->
    let before_seq = latest_ring_seq () in
    let claude = find_agent_name_by_prefix config "claude" in
    let _ =
      Workspace.add_task config ~title:"Claimed Done Task" ~priority:1 ~description:""
    in
    let claim_result = Workspace.claim_task config ~agent_name:claude ~task_id:"task-001" in
    Alcotest.(check bool) "claim succeeds" true (contains_check claim_result);
    let done_result =
      transition_done
        config
        ~agent_name:claude
        ~task_id:"task-001"
        ~notes:"claim-to-done path"
    in
    Alcotest.(check bool) "claimed done succeeds" true (contains_check done_result);
    let audit_entries = Audit_log.read_entries ~n:50 config in
    Alcotest.(check bool)
      "claimed done audit recorded"
      true
      (audit_has_entry
         audit_entries
         ~agent_id:claude
         ~action_pred:(function
           | Audit_log.DoneTask -> true
           | _ -> false)
         ~details:
           [ "event_family", "task_transition"
           ; "transition", "done"
           ; "task_id", "task-001"
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
    Alcotest.(check bool) "claimed done telemetry completion recorded" true has_completed;
    let ring_entries =
      Log.Ring.recent ~limit:50 ~module_filter:"Task" ~since_seq:before_seq ()
    in
    Alcotest.(check bool)
      "claimed done ring done recorded"
      true
      (ring_has_entry
         ring_entries
         ~details:
           [ "event_family", "task_transition"
           ; "transition", "done"
           ; "task_id", "task-001"
           ]))
;;

let test_claim_next_existing_task_does_not_emit_release_observability () =
  with_test_env (fun config ->
    let before_seq = latest_ring_seq () in
    let claude = find_agent_name_by_prefix config "claude" in
    let _ = Workspace.add_task config ~title:"First" ~priority:1 ~description:"" in
    let _ = Workspace.add_task config ~title:"Second" ~priority:2 ~description:"" in
    (match Workspace.claim_next_r config ~agent_name:claude () with
     | Workspace.Claim_next_claimed _ -> ()
     | _ -> Alcotest.fail "expected first claim_next_r to succeed");
    (match Workspace.claim_next_r config ~agent_name:claude () with
     | Workspace.Claim_next_claimed { released_task_id = None; task_id; _ } ->
       Alcotest.(check string) "keeps task id" "task-001" task_id
     | Workspace.Claim_next_claimed { released_task_id = Some _; _ } ->
       Alcotest.fail "second claim_next_r should not auto-release"
     | _ -> Alcotest.fail "expected existing task on second claim_next_r");
    let audit_entries = Audit_log.read_entries ~n:50 config in
    Alcotest.(check bool)
      "audit release not recorded"
      false
      (audit_has_entry
         audit_entries
         ~agent_id:claude
         ~action_pred:(function
           | Audit_log.ReleaseTask -> true
           | _ -> false)
         ~details:
           [ "event_family", "task_transition"
           ; "transition", "release"
           ; "task_id", "task-001"
           ]);
    let ring_entries =
      Log.Ring.recent ~limit:50 ~module_filter:"Task" ~since_seq:before_seq ()
    in
    Alcotest.(check bool)
      "ring release not recorded"
      false
      (ring_has_entry
         ring_entries
         ~details:
           [ "event_family", "task_transition"
           ; "transition", "release"
           ; "task_id", "task-001"
           ]))
;;

(* ============================================================ *)
(* Pause/Resume Tests                                            *)
(* ============================================================ *)

let test_pause_workspace () =
  with_test_env (fun config ->
    Workspace.pause config ~by:"claude" ~reason:"Testing pause";
    Alcotest.(check bool) "workspace is paused" true (Workspace.is_paused config))
;;

let test_resume_workspace () =
  with_test_env (fun config ->
    Workspace.pause config ~by:"claude" ~reason:"Testing pause";
    let result = Workspace.resume config ~by:"claude" in
    match result with
    | `Resumed -> Alcotest.(check bool) "workspace resumed" true (not (Workspace.is_paused config))
    | _ -> Alcotest.fail "Expected Resumed")
;;

let test_resume_not_paused () =
  with_test_env (fun config ->
    let result = Workspace.resume config ~by:"claude" in
    match result with
    | `Already_running -> ()
    | _ -> Alcotest.fail "Expected Already_running")
;;

let test_pause_info () =
  with_test_env (fun config ->
    Workspace.pause config ~by:"claude" ~reason:"Maintenance";
    match Workspace.pause_info config with
    | Some (Some by, Some reason, Some _) ->
      Alcotest.(check string) "paused by" "claude" by;
      Alcotest.(check string) "reason" "Maintenance" reason
    | _ -> Alcotest.fail "Expected pause info")
;;

let test_pause_info_not_paused () =
  with_test_env (fun config ->
    match Workspace.pause_info config with
    | None -> ()
    | Some _ -> Alcotest.fail "Expected None")
;;

(* ============================================================ *)
(* Raw Data Accessor Tests                                       *)
(* ============================================================ *)

let test_get_tasks_raw () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Task 1" ~priority:1 ~description:"" in
    let _ = Workspace.add_task config ~title:"Task 2" ~priority:2 ~description:"" in
    let tasks = Workspace.get_tasks_raw config in
    Alcotest.(check int) "two tasks" 2 (List.length tasks))
;;

let test_get_tasks_raw_empty () =
  with_test_env (fun config ->
    let tasks = Workspace.get_tasks_raw config in
    Alcotest.(check int) "no tasks" 0 (List.length tasks))
;;

let test_get_agents_raw () =
  with_test_env (fun config ->
    let _ = Workspace.bind_session config ~agent_name:"gemini" ~capabilities:[ "test" ] () in
    let agents : Masc_domain.agent list = Workspace.get_agents_raw config in
    (* claude from init + gemini *)
    Alcotest.(check bool) "at least 2 agents" true (List.length agents >= 2))
;;

let remove_agent_files config =
  let dir = Workspace.agents_dir config in
  if Sys.file_exists dir
  then
    Sys.readdir dir
    |> Array.iter (fun name ->
      if Filename.check_suffix name ".json" then Sys.remove (Filename.concat dir name))
;;

let runtime_agent ?(status = Masc_domain.Active) name : Masc_domain.agent =
  let now = Masc_domain.now_iso () in
  let meta : Masc_domain.agent_meta =
    { session_id = "runtime-hook:" ^ name
    ; agent_type = "keeper"
    ; pid = None
    ; hostname = None
    ; tty = None
    ; parent_task = None
    ; keeper_name = Some name
    ; keeper_id = None
    }
  in
  { id = None
  ; name
  ; agent_type = "keeper"
  ; status
  ; capabilities = []
  ; current_task = None
  ; session_bound_at = now
  ; last_seen = now
  ; meta = Some meta
  }
;;

let test_get_active_agents_falls_back_to_state_when_agent_files_missing () =
  with_test_env (fun config ->
    let state = Workspace.read_state config in
    Workspace.write_state
      config
      { state with active_agents = [ "keeper-albini-agent"; ""; "keeper-albini-agent" ] };
    remove_agent_files config;
    let agents = Workspace.get_active_agents config in
    match agents with
    | [ agent ] ->
      Alcotest.(check string) "agent name" "keeper-albini-agent" agent.name;
      Alcotest.(check string) "agent type" "keeper" agent.agent_type;
      Alcotest.(check string)
        "agent status"
        "active"
        (Masc_domain.agent_status_to_string agent.status);
      (match agent.meta with
       | Some meta ->
         Alcotest.(check string)
           "synthetic session id"
           "workspace-state:keeper-albini-agent"
           meta.session_id
       | None -> Alcotest.fail "expected synthetic agent meta")
    | _ -> Alcotest.failf "expected one state-backed agent, got %d" (List.length agents))
;;

let test_get_active_agents_merges_state_with_file_backed_agents () =
  with_test_env (fun config ->
    let file_agent =
      match Workspace.get_active_agents config with
      | [ agent ] -> agent
      | agents -> Alcotest.failf "expected one file-backed agent, got %d" (List.length agents)
    in
    let state = Workspace.read_state config in
    Workspace.write_state
      config
      { state with
        active_agents =
          [ file_agent.name
          ; "keeper-state-only-agent"
          ; ""
          ; "keeper-state-only-agent"
          ]
      };
    let agents = Workspace.get_active_agents config in
    let names = List.map (fun (agent : Masc_domain.agent) -> agent.name) agents in
    Alcotest.(check bool)
      "keeps file-backed agent"
      true
      (List.exists (String.equal file_agent.name) names);
    Alcotest.(check bool)
      "adds state-only agent"
      true
      (List.exists (String.equal "keeper-state-only-agent") names);
    Alcotest.(check int) "deduped active agents" 2 (List.length agents);
    let output = Workspace.status config in
    Alcotest.(check bool)
      "direct status includes state-only agent"
      true
      (str_contains output "keeper-state-only-agent → idle"))
;;

let test_get_active_agents_filters_inactive_runtime_agents () =
  with_test_env (fun config ->
    let previous = Atomic.get Workspace_hooks.runtime_agents_fn in
    Fun.protect
      ~finally:(fun () -> Atomic.set Workspace_hooks.runtime_agents_fn previous)
      (fun () ->
        Atomic.set Workspace_hooks.runtime_agents_fn (fun hook_config ->
          if String.equal hook_config.base_path config.base_path
          then
            [ runtime_agent "keeper-runtime-active-agent"
            ; runtime_agent ~status:Masc_domain.Inactive "keeper-runtime-inactive-agent"
            ]
          else []);
        let agents = Workspace.get_active_agents config in
        let names = List.map (fun (agent : Masc_domain.agent) -> agent.name) agents in
        Alcotest.(check bool)
          "keeps active runtime agent"
          true
          (List.exists (String.equal "keeper-runtime-active-agent") names);
        Alcotest.(check bool)
          "filters inactive runtime agent"
          false
          (List.exists (String.equal "keeper-runtime-inactive-agent") names);
        let output = Workspace.status config in
        Alcotest.(check bool)
          "direct status hides inactive runtime agent"
          false
          (str_contains output "keeper-runtime-inactive-agent")))
;;

let test_get_messages_raw () =
  with_test_env (fun config ->
    let _ = Workspace.broadcast config ~from_agent:"claude" ~content:"Message 1" in
    let _ = Workspace.broadcast config ~from_agent:"claude" ~content:"Message 2" in
    let msgs = Workspace.get_messages_raw config ~since_seq:0 ~limit:10 in
    Alcotest.(check bool) "has messages" true (List.length msgs >= 2))
;;

let test_is_agent_session_bound () =
  with_test_env (fun config ->
    (* claude is bound from init *)
    (* Note: agent names are auto-generated with nicknames, so we check by type prefix *)
    let agents : Masc_domain.agent list = Workspace.get_agents_raw config in
    let has_agent =
      List.exists
        (fun (a : Masc_domain.agent) ->
           String.length a.name >= 6 && String.sub a.name 0 6 = "claude")
        agents
    in
    Alcotest.(check bool) "claude is joined" true has_agent)
;;

(* ============================================================ *)
(* Done Transition Result Variant Tests                          *)
(* ============================================================ *)

let test_transition_done_r_success () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let result =
      transition_done_r config ~agent_name:"claude" ~task_id:"task-001" ~notes:"Done!"
    in
    match result with
    | Ok msg -> Alcotest.(check bool) "done success" true (contains_check msg)
    | Error _ -> Alcotest.fail "Expected Ok")
;;

let test_transition_done_r_not_claimed () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let result =
      transition_done_r config ~agent_name:"claude" ~task_id:"task-001" ~notes:""
    in
    match result with
    | Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState msg)) ->
      Alcotest.(check bool) "mentions todo state" true (str_contains msg "todo")
    | _ -> Alcotest.fail "Expected TaskInvalidState")
;;

let test_transition_done_r_not_found () =
  with_test_env (fun config ->
    let result =
      transition_done_r config ~agent_name:"claude" ~task_id:"task-999" ~notes:""
    in
    match result with
    | Error (Masc_domain.Task (Masc_domain.Task_error.NotFound _)) -> ()
    | _ -> Alcotest.fail "Expected TaskNotFound")
;;

let test_claim_task_r_success () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let result = Workspace.claim_task_r config ~agent_name:"claude" ~task_id:"task-001" () in
    match result with
    | Ok outcome -> Alcotest.(check bool) "claim success" true (str_contains outcome.message "claimed")
    | Error _ -> Alcotest.fail "Expected Ok")
;;

let test_claim_task_r_blocks_done_default_policy () =
  with_test_env (fun config ->
    let _ =
      Workspace.add_task config ~title:"Completed default-policy task" ~priority:1 ~description:""
    in
    update_task config "task-001" (fun (t : Masc_domain.task) ->
      { t with task_status = done_status "prior-agent"; reclaim_policy = None });
    match Workspace.claim_task_r config ~agent_name:"claude" ~task_id:"task-001" () with
    | Error _ ->
      let task = task_by_id config "task-001" in
      Alcotest.(check string)
        "default completed task stays terminal"
        "done"
        (Masc_domain.task_status_to_string task.task_status)
    | Ok _ -> Alcotest.fail "completed default-policy task must not be claimable")
;;

let test_claim_task_r_reclaims_done_allow_reclaim () =
  with_test_env (fun config ->
    let _ =
      Workspace.add_task config ~title:"Completed allow-reclaim task" ~priority:1 ~description:""
    in
    update_task config "task-001" (fun (t : Masc_domain.task) ->
      { t with
        task_status = done_status "prior-agent"
      ; reclaim_policy = Some Masc_domain.Allow_reclaim
      });
    match Workspace.claim_task_r config ~agent_name:"claude" ~task_id:"task-001" () with
    | Ok outcome ->
      Alcotest.(check bool)
        "direct completed-task reclaim succeeds"
        true
        (str_contains outcome.message "claimed");
      assert_claimed_by config "task-001" "claude";
      let task = task_by_id config "task-001" in
      Alcotest.(check (option string))
        "allow_reclaim policy cleared"
        None
        (Option.map Masc_domain.task_reclaim_policy_to_string task.reclaim_policy)
    | Error e ->
      Alcotest.fail
        ("completed allow-reclaim task should be claimable: "
         ^ Masc_domain.masc_error_to_string e))
;;

let test_claim_task_r_already_claimed () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"gemini" ~task_id:"task-001" in
    let result = Workspace.claim_task_r config ~agent_name:"claude" ~task_id:"task-001" () in
    match result with
    | Error (Masc_domain.Task (Masc_domain.Task_error.AlreadyClaimed _)) -> ()
    | _ -> Alcotest.fail "Expected TaskAlreadyClaimed")
;;

(* Schedule-level scope fallback (#20673): a keeper must not idle when no
   in-scope task passes [task_filter] while an out-of-scope task is claimable.
   Hard scope returns no_eligible; [allow_scope_fallback] widens to all_tasks
   and flags [scope_widened]. *)
let test_scope_widen_claims_unscoped_when_scope_blocks_all () =
  with_test_env (fun config ->
    let _ =
      Workspace.add_task config ~title:"only open" ~priority:1 ~description:""
    in
    let agent_name = "claude" in
    (* task_filter rejects everything -> no scoped task is eligible. *)
    let task_filter (_t : Masc_domain.task) = false in
    (* Hard scope (default allow_scope_fallback=false): scope excludes the task
       -> no eligible. *)
    (match Workspace.claim_next_r config ~agent_name ~task_filter () with
     | Workspace.Claim_next_no_eligible _ -> ()
     | Workspace.Claim_next_claimed { task_id; _ } ->
       Alcotest.failf "hard scope must not claim, got %s" task_id
     | _ -> Alcotest.fail "expected no_eligible under hard scope");
    (* Fallback: widen drops scope -> claims the out-of-scope task and flags
       scope_widened. *)
    match
      Workspace.claim_next_r config ~agent_name ~task_filter
        ~allow_scope_fallback:true ()
    with
    | Workspace.Claim_next_claimed { task_id; scope_widened; _ } ->
      Alcotest.(check string) "claimed via widen" "task-001" task_id;
      Alcotest.(check bool) "scope_widened flag set" true scope_widened
    | Workspace.Claim_next_no_eligible _ ->
      Alcotest.fail "fallback must claim the out-of-scope task, got no_eligible"
    | _ -> Alcotest.fail "expected claim under fallback")
;;

(* ============================================================ *)
(* GC (Garbage Collection) Tests                                 *)
(* ============================================================ *)

let test_gc_no_cleanup_needed () =
  with_test_env (fun config ->
    let result = Workspace.gc config () in
    Alcotest.(check bool) "gc result has content" true (String.length result > 0);
    Alcotest.(check bool) "no zombie cleanup" true (str_contains result "No zombie"))
;;

let test_gc_with_tasks () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Recent Task" ~priority:1 ~description:"" in
    let result = Workspace.gc config ~days:1 () in
    Alcotest.(check bool) "gc with recent task" true (String.length result > 0))
;;

(* Well before any [days]-based cutoff so [is_old] is true for these tasks. *)
let gc_ancient_ts = "2020-01-01T00:00:00Z"

let gc_make_task ~id ~created_at ~status : Masc_domain.task =
  { id
  ; title = "GC " ^ id
  ; description = ""
  ; task_status = status
  ; priority = 1
  ; files = []
  ; created_at
  ; created_by = None
  ; predecessor_task_id = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  }
;;

let gc_backlog_has config task_id =
  List.exists
    (fun (t : Masc_domain.task) -> String.equal t.id task_id)
    (Workspace.read_backlog config).tasks
;;

let gc_message_path_with_content config content =
  let messages_dir = Workspace.messages_dir config in
  let matching_paths =
    Sys.readdir messages_dir
    |> Array.to_list
    |> List.filter_map (fun name ->
      let path = Filename.concat messages_dir name in
      match Workspace.read_json config path with
      | `Assoc fields ->
        (match List.assoc_opt "content" fields with
         | Some (`String actual) when String.equal actual content -> Some path
         | _ -> None)
      | _ -> None)
  in
  match matching_paths with
  | [ path ] -> path
  | paths ->
    Alcotest.failf
      "expected one message with content %S, got %d"
      content
      (List.length paths)
;;

let gc_backdate_message config ~content =
  let path = gc_message_path_with_content config content in
  let json = Workspace.read_json config path in
  let updated =
    match json with
    | `Assoc fields ->
      `Assoc (("timestamp", `String gc_ancient_ts) :: List.remove_assoc "timestamp" fields)
    | _ -> Alcotest.fail "expected message object"
  in
  Workspace.write_json config path updated;
  path
;;

(* RFC-0220: an old AwaitingVerification obligation must survive GC in the live
   backlog — masc_transition and dashboard verification read the live backlog
   only, so archiving strands its approve/reject path (task-1537 incident). *)
let test_gc_preserves_awaiting_verification () =
  with_test_env (fun config ->
    let task =
      gc_make_task
        ~id:"task-900"
        ~created_at:gc_ancient_ts
        ~status:
          (Masc_domain.AwaitingVerification
             { assignee = "claude"
             ; submitted_at = gc_ancient_ts
             ; verification_id = "verif-900"
             ; phase = Masc_domain.Awaiting_verifier
             })
    in
    write_tasks config [ task ];
    let _ = Workspace.gc config ~days:1 () in
    Alcotest.(check bool)
      "awaiting_verification obligation kept in live backlog"
      true
      (gc_backlog_has config "task-900");
    Alcotest.(check bool)
      "awaiting_verification obligation not archived"
      false
      (List.mem 900 (Workspace.read_archive_task_ids config)))
;;

(* Self-healing: a non-terminal task stranded in the archive (the pre-fix
   symptom) is pulled back into the live backlog on the next GC pass. *)
let test_gc_restores_orphaned_nonterminal_from_archive () =
  with_test_env (fun config ->
    let orphan =
      gc_make_task
        ~id:"task-901"
        ~created_at:gc_ancient_ts
        ~status:
          (Masc_domain.AwaitingVerification
             { assignee = "claude"
             ; submitted_at = gc_ancient_ts
             ; verification_id = "verif-901"
             ; phase = Masc_domain.Awaiting_verifier
             })
    in
    (* Simulate the orphaning a buggy GC pass produced: obligation lives in the
       archive only, absent from the backlog. *)
    Workspace.append_archive_tasks config [ orphan ];
    Alcotest.(check bool)
      "precondition: orphan not yet in backlog"
      false
      (gc_backlog_has config "task-901");
    let _ = Workspace.gc config ~days:1 () in
    Alcotest.(check bool)
      "orphaned obligation restored to live backlog"
      true
      (gc_backlog_has config "task-901");
    Alcotest.(check bool)
      "restored obligation removed from archive"
      false
      (List.mem 901 (Workspace.read_archive_task_ids config)))
;;

(* The same GC pass that restores an archive-only non-terminal task must use the
   restored live task set when pruning old messages.  Otherwise the restored
   task survives but its old task-reference message is deleted immediately. *)
let test_gc_restored_task_preserves_old_messages_same_pass () =
  with_test_env (fun config ->
    let orphan =
      gc_make_task
        ~id:"task-904"
        ~created_at:gc_ancient_ts
        ~status:
          (Masc_domain.AwaitingVerification
             { assignee = "claude"
             ; submitted_at = gc_ancient_ts
             ; verification_id = "verif-904"
             ; phase = Masc_domain.Awaiting_verifier
             })
    in
    Workspace.append_archive_tasks config [ orphan ];
    let content = "verification context for task-904" in
    let _ =
      Workspace.broadcast
        config
        ~from_agent:"claude"
        ~content
    in
    let message_path = gc_backdate_message config ~content in
    let _ = Workspace.gc config ~days:1 () in
    Alcotest.(check bool)
      "orphaned obligation restored to live backlog"
      true
      (gc_backlog_has config "task-904");
    Alcotest.(check bool)
      "old message referencing restored task preserved"
      true
      (Sys.file_exists message_path))
;;

(* Regression guard: terminal (Done/Cancelled) tasks past the cutoff are still
   archived, so the fix does not disable GC's intended behaviour. *)
let test_gc_archives_terminal_tasks () =
  with_test_env (fun config ->
    let done_task =
      gc_make_task
        ~id:"task-902"
        ~created_at:gc_ancient_ts
        ~status:
          (Masc_domain.Done
             { assignee = "claude"; completed_at = gc_ancient_ts; notes = None })
    in
    let cancelled_task =
      gc_make_task
        ~id:"task-903"
        ~created_at:gc_ancient_ts
        ~status:
          (Masc_domain.Cancelled
             { cancelled_by = "claude"; cancelled_at = gc_ancient_ts; reason = None })
    in
    write_tasks config [ done_task; cancelled_task ];
    let _ = Workspace.gc config ~days:1 () in
    Alcotest.(check bool)
      "done task removed from live backlog"
      false
      (gc_backlog_has config "task-902");
    Alcotest.(check bool)
      "cancelled task removed from live backlog"
      false
      (gc_backlog_has config "task-903");
    let archive_ids = Workspace.read_archive_task_ids config in
    Alcotest.(check bool) "done task archived" true (List.mem 902 archive_ids);
    Alcotest.(check bool) "cancelled task archived" true (List.mem 903 archive_ids))
;;

(* ============================================================ *)
(* Task ID Parsing Tests                                         *)
(* ============================================================ *)

let test_task_id_to_int_valid () =
  match Workspace.task_id_to_int "task-001" with
  | Some 1 -> ()
  | _ -> Alcotest.fail "Expected Some 1"
;;

let test_task_id_to_int_large () =
  match Workspace.task_id_to_int "task-999" with
  | Some 999 -> ()
  | _ -> Alcotest.fail "Expected Some 999"
;;

let test_task_id_to_int_invalid_prefix () =
  match Workspace.task_id_to_int "issue-001" with
  | None -> ()
  | Some _ -> Alcotest.fail "Expected None"
;;

let test_task_id_to_int_empty () =
  match Workspace.task_id_to_int "" with
  | None -> ()
  | Some _ -> Alcotest.fail "Expected None"
;;

let test_task_id_to_int_only_prefix () =
  match Workspace.task_id_to_int "task-" with
  | None -> ()
  | Some _ -> Alcotest.fail "Expected None"
;;

(* ============================================================ *)
(* Update Agent Tests                                            *)
(* ============================================================ *)

(* test_update_agent_status / _capabilities / _not_found removed (2026-06-09):
   Workspace.update_agent_r deleted with the dead agent-status surface. *)

(* ============================================================ *)
(* Archive Task Tests                                            *)
(* ============================================================ *)

let test_append_archive_tasks () =
  with_test_env (fun config ->
    let task : Masc_domain.task =
      { id = "task-test"
      ; title = "Archive Test"
      ; description = "Test description"
      ; task_status =
          Masc_domain.Done
            { assignee = "claude"; completed_at = "2026-01-01T00:00:00Z"; notes = None }
      ; priority = 1
      ; files = []
      ; created_at = "2026-01-01T00:00:00Z"
      ; created_by = None
      ; predecessor_task_id = None
      ; contract = None
      ; handoff_context = None
      ; cycle_count = 0
      ; reclaim_policy = None
      ; do_not_reclaim_reason = None
      }
    in
    Workspace.append_archive_tasks config [ task ];
    (* Add a new task to verify archive max ID is checked *)
    let result = Workspace.add_task config ~title:"New Task" ~priority:1 ~description:"" in
    Alcotest.(check bool) "task added" true (contains_check result))
;;

(* ============================================================ *)
(* RFC-0323 W2: predecessor_task_id (linked re-run tasks)        *)
(* ============================================================ *)

let predecessor_of config task_id =
  match
    List.find_opt
      (fun (t : Masc_domain.task) -> String.equal t.id task_id)
      (Workspace.read_backlog config).tasks
  with
  | Some t -> t.predecessor_task_id
  | None -> Alcotest.fail (Printf.sprintf "%s missing from backlog" task_id)
;;

let test_predecessor_unknown_rejected () =
  with_test_env (fun config ->
    match
      Workspace.add_task_with_result
        config
        ~title:"Re-run"
        ~priority:2
        ~description:""
        ~predecessor_task_id:"task-999"
    with
    | Error (Workspace.Unknown_predecessor "task-999") -> ()
    | Error e ->
      Alcotest.fail
        ("unexpected error: " ^ Workspace.add_task_error_to_string e)
    | Ok _ -> Alcotest.fail "unknown predecessor accepted")
;;

let test_predecessor_non_terminal_rejected () =
  with_test_env (fun config ->
    let _ =
      Workspace.add_task config ~title:"Original" ~priority:2 ~description:""
    in
    match
      Workspace.add_task_with_result
        config
        ~title:"Re-run of original"
        ~priority:2
        ~description:""
        ~predecessor_task_id:"task-001"
    with
    | Error
        (Workspace.Predecessor_not_terminal
           { predecessor_task_id = "task-001"; status = "todo" }) -> ()
    | Error e ->
      Alcotest.fail
        ("unexpected error: " ^ Workspace.add_task_error_to_string e)
    | Ok _ -> Alcotest.fail "non-terminal predecessor accepted")
;;

let test_predecessor_terminal_accepted_and_persisted () =
  with_test_env (fun config ->
    let _ =
      Workspace.add_task config ~title:"Original" ~priority:2 ~description:""
    in
    let forced =
      Workspace.force_done_task_r
        config
        ~agent_name:"claude"
        ~task_id:"task-001"
        ~notes:"done"
        ()
    in
    Alcotest.(check bool)
      "predecessor completed"
      true
      (match forced with Ok _ -> true | Error _ -> false);
    match
      Workspace.add_task_with_result
        config
        ~title:"Re-run of original"
        ~priority:2
        ~description:""
        ~predecessor_task_id:"task-001"
    with
    | Ok created ->
      (* read_backlog re-decodes from disk: persistence + codec round-trip *)
      Alcotest.(check (option string))
        "predecessor persisted"
        (Some "task-001")
        (predecessor_of config created.task_id)
    | Error e ->
      Alcotest.fail
        ("terminal predecessor rejected: " ^ Workspace.add_task_error_to_string e))
;;

let test_predecessor_blank_treated_as_none () =
  with_test_env (fun config ->
    match
      Workspace.add_task_with_result
        config
        ~title:"No link"
        ~priority:2
        ~description:""
        ~predecessor_task_id:"  "
    with
    | Ok created ->
      Alcotest.(check (option string))
        "blank predecessor is None"
        None
        (predecessor_of config created.task_id)
    | Error e ->
      Alcotest.fail
        ("blank predecessor rejected: " ^ Workspace.add_task_error_to_string e))
;;

let test_predecessor_codec_absent_and_malformed () =
  (* Encoder omits the key when None (old readers never see it). *)
  let without =
    gc_make_task ~id:"task-c1" ~created_at:gc_ancient_ts ~status:Masc_domain.Todo
  in
  let json = Masc_domain.task_to_yojson without in
  let keys = match json with `Assoc kvs -> List.map fst kvs | _ -> [] in
  Alcotest.(check bool)
    "key omitted when None"
    false
    (List.mem "predecessor_task_id" keys);
  (* Absent key decodes to None (pre-W2 backlogs parse unchanged). *)
  (match Masc_domain.task_of_yojson json with
   | Ok t ->
     Alcotest.(check (option string)) "absent -> None" None t.predecessor_task_id
   | Error e -> Alcotest.fail ("decode without key failed: " ^ e));
  (* Present string value round-trips. *)
  let with_link = { without with predecessor_task_id = Some "task-000" } in
  (match Masc_domain.task_of_yojson (Masc_domain.task_to_yojson with_link) with
   | Ok t ->
     Alcotest.(check (option string))
       "round-trip"
       (Some "task-000")
       t.predecessor_task_id
   | Error e -> Alcotest.fail ("round-trip decode failed: " ^ e));
  (* Malformed value degrades to None instead of erroring — a decode Error
     would make backlog_of_yojson silently drop the whole task. *)
  let malformed =
    match json with
    | `Assoc kvs -> `Assoc (kvs @ [ "predecessor_task_id", `Int 7 ])
    | other -> other
  in
  match Masc_domain.task_of_yojson malformed with
  | Ok t ->
    Alcotest.(check (option string)) "malformed -> None" None t.predecessor_task_id
  | Error e -> Alcotest.fail ("malformed value dropped the task: " ^ e)
;;

(* ============================================================ *)
(* Test Runner                                                   *)
(* ============================================================ *)

let () =
  Random.init 42;
  Alcotest.run
    "Workspace Coverage"
    [ (* === Batch Operations === *)
      ( "batch"
      , [ Alcotest.test_case "add tasks" `Quick test_batch_add_tasks
        ; Alcotest.test_case "empty list" `Quick test_batch_add_empty_list
        ; Alcotest.test_case "single task" `Quick test_batch_add_single_task
        ; Alcotest.test_case
            "preserves priorities"
            `Quick
            test_batch_add_preserves_priorities
        ] )
    ; (* === Status === *)
      ( "status"
      , [ Alcotest.test_case
            "hides stale current_task on read without writing"
            `Quick
            test_status_hides_stale_agent_current_task_without_writing
        ] )
    ; (* === Claim Next === *)
      ( "claim_next"
      , [ Alcotest.test_case "basic" `Quick test_claim_next_basic
        ; Alcotest.test_case "priority order" `Quick test_claim_next_priority_order
        ; Alcotest.test_case "empty backlog" `Quick test_claim_next_empty_backlog
        ; Alcotest.test_case "all claimed" `Quick test_claim_next_all_claimed
        ; Alcotest.test_case
            "skips done/cancelled"
            `Quick
            test_claim_next_skips_done_and_cancelled
        ; Alcotest.test_case
            "terminal-only backlog"
            `Quick
            test_claim_next_terminal_only_backlog
        ; Alcotest.test_case "consecutive" `Quick test_claim_next_consecutive
        ; Alcotest.test_case
            "reconciles stale current_task"
            `Quick
            test_claim_next_reconciles_stale_agent_current_task
        ; Alcotest.test_case
            "#10421: preserves existing task"
            `Quick
            test_claim_next_preserves_existing_task
        ; Alcotest.test_case
            "#10421: preserved task not claimable"
            `Quick
            test_claim_next_preserved_task_not_claimable_by_others
        ; Alcotest.test_case
            "#10421: preserved task result field"
            `Quick
            test_claim_next_r_preserved_task_field
        ; Alcotest.test_case
            "release hard-stop blocks future claim_next"
            `Quick
            test_release_hard_stop_blocks_future_claim_next
        ; Alcotest.test_case
            "release hard-stop blocks direct reclaim"
            `Quick
            test_release_hard_stop_blocks_direct_reclaim
        ; Alcotest.test_case
            "completed allow-reclaim task is scheduled"
            `Quick
            test_claim_next_reclaims_done_allow_reclaim
        ; Alcotest.test_case
            "completed block-reclaim task is skipped"
            `Quick
            test_claim_next_blocks_done_block_reclaim
        ; Alcotest.test_case
            "legacy auto-cycle text is ignored"
            `Quick
            test_claim_next_ignores_legacy_auto_cycle_text
        ; Alcotest.test_case
            "routing handoff text is ignored"
            `Quick
            test_claim_next_ignores_routing_handoff_text
        ; Alcotest.test_case
            "legacy text does not alter priority"
            `Quick
            test_claim_next_does_not_deprioritize_legacy_text
        ; Alcotest.test_case
            "release cycles do not create auto block"
            `Quick
            test_release_cycles_do_not_create_auto_do_not_reclaim
        ; Alcotest.test_case
            "cycle 15 release does not create auto hard stop"
            `Quick
            test_release_cycle_15_does_not_create_auto_hard_stop
        ; Alcotest.test_case
            "failed verification stays repair-claimable"
            `Quick
            test_claim_next_allows_failed_verification_repair
        ] )
    ; (* === Update Priority === *)
      ( "update_priority"
      , [ Alcotest.test_case "basic" `Quick test_update_priority
        ; Alcotest.test_case "nonexistent" `Quick test_update_priority_nonexistent
        ; Alcotest.test_case "negative" `Quick test_update_priority_negative
        ] )
    ; (* === Cancel Task === *)
      ( "cancel"
      , [ Alcotest.test_case "todo task" `Quick test_cancel_task_todo
        ; Alcotest.test_case "claimed by self" `Quick test_cancel_task_claimed_by_self
        ; Alcotest.test_case "claimed by other" `Quick test_cancel_task_claimed_by_other
        ; Alcotest.test_case "nonexistent" `Quick test_cancel_task_nonexistent
        ; Alcotest.test_case "done task" `Quick test_cancel_done_task
        ] )
    ; (* === Transition Task === *)
      ( "transition"
      , [ Alcotest.test_case "claim" `Quick test_transition_claim
        ; Alcotest.test_case "start" `Quick test_transition_start
        ; Alcotest.test_case "release" `Quick test_transition_release
        ; Alcotest.test_case
            "release accepts keeper transport alias"
            `Quick
            test_transition_release_keeper_transport_alias
        ; Alcotest.test_case
            "release accepts generated nickname alias"
            `Quick
            test_transition_release_generated_nickname_alias
        ; Alcotest.test_case "release todo no-op" `Quick test_transition_release_todo_noop
        ; Alcotest.test_case "invalid" `Quick test_transition_invalid
        ; Alcotest.test_case
            "submit_for_verification requires notes"
            `Quick
            test_transition_submit_for_verification_requires_notes
        ; Alcotest.test_case "version mismatch" `Quick test_transition_version_mismatch
        ; Alcotest.test_case "done idempotent" `Quick test_transition_done_idempotent
        ; Alcotest.test_case
            "done awards task reward once"
            `Quick
            test_transition_done_awards_task_reward_once
        ; Alcotest.test_case "cancel idempotent" `Quick test_transition_cancel_idempotent
        ] )
    ; (* === Observability === *)
      ( "observability"
      , [ Alcotest.test_case
            "join leave fan-out"
            `Quick
            test_join_leave_emit_observability
        ; Alcotest.test_case
            "task transitions fan-out"
            `Quick
            test_task_transitions_emit_observability
        ; Alcotest.test_case
            "claimed done fan-out"
            `Quick
            test_transition_done_from_claimed_emits_observability
        ; Alcotest.test_case
            "claim_next existing task no release fan-out"
            `Quick
            test_claim_next_existing_task_does_not_emit_release_observability
        ] )
    ; (* === Pause/Resume === *)
      ( "pause_resume"
      , [ Alcotest.test_case "pause" `Quick test_pause_workspace
        ; Alcotest.test_case "resume" `Quick test_resume_workspace
        ; Alcotest.test_case "resume not paused" `Quick test_resume_not_paused
        ; Alcotest.test_case "pause info" `Quick test_pause_info
        ; Alcotest.test_case "pause info not paused" `Quick test_pause_info_not_paused
        ] )
    ; (* === Raw Data Accessors === *)
      ( "raw_data"
      , [ Alcotest.test_case "get tasks raw" `Quick test_get_tasks_raw
        ; Alcotest.test_case "get tasks raw empty" `Quick test_get_tasks_raw_empty
        ; Alcotest.test_case "get agents raw" `Quick test_get_agents_raw
        ; Alcotest.test_case
            "get active agents falls back to state"
            `Quick
            test_get_active_agents_falls_back_to_state_when_agent_files_missing
        ; Alcotest.test_case
            "get active agents merges state and file-backed"
            `Quick
            test_get_active_agents_merges_state_with_file_backed_agents
        ; Alcotest.test_case
            "get active agents filters inactive runtime agents"
            `Quick
            test_get_active_agents_filters_inactive_runtime_agents
        ; Alcotest.test_case "get messages raw" `Quick test_get_messages_raw
        ; Alcotest.test_case "is agent joined" `Quick test_is_agent_session_bound
        ] )
    ; (* === Result Variants === *)
      ( "result_variants"
      , [ Alcotest.test_case
            "transition done success"
            `Quick
            test_transition_done_r_success
        ; Alcotest.test_case
            "transition done not claimed"
            `Quick
            test_transition_done_r_not_claimed
        ; Alcotest.test_case
            "transition done not found"
            `Quick
            test_transition_done_r_not_found
        ; Alcotest.test_case "claim_task_r success" `Quick test_claim_task_r_success
        ; Alcotest.test_case
            "claim_task_r blocks default completed task"
            `Quick
            test_claim_task_r_blocks_done_default_policy
        ; Alcotest.test_case
            "claim_task_r reclaims allow-reclaim completed task"
            `Quick
            test_claim_task_r_reclaims_done_allow_reclaim
        ; Alcotest.test_case
            "claim_task_r already claimed"
            `Quick
            test_claim_task_r_already_claimed
        ; Alcotest.test_case
            "scope fallback claims out-of-scope when scope blocks all"
            `Quick
            test_scope_widen_claims_unscoped_when_scope_blocks_all
        ] )
    ; (* === GC === *)
      ( "gc"
      , [ Alcotest.test_case "no cleanup" `Quick test_gc_no_cleanup_needed
        ; Alcotest.test_case "with tasks" `Quick test_gc_with_tasks
        ; Alcotest.test_case
            "preserves awaiting_verification"
            `Quick
            test_gc_preserves_awaiting_verification
        ; Alcotest.test_case
            "restores orphaned non-terminal from archive"
            `Quick
            test_gc_restores_orphaned_nonterminal_from_archive
        ; Alcotest.test_case
            "restored task preserves old messages same pass"
            `Quick
            test_gc_restored_task_preserves_old_messages_same_pass
        ; Alcotest.test_case
            "archives terminal tasks"
            `Quick
            test_gc_archives_terminal_tasks
        ] )
    ; (* === Task ID Parsing === *)
      ( "task_id"
      , [ Alcotest.test_case "valid" `Quick test_task_id_to_int_valid
        ; Alcotest.test_case "large" `Quick test_task_id_to_int_large
        ; Alcotest.test_case "invalid prefix" `Quick test_task_id_to_int_invalid_prefix
        ; Alcotest.test_case "empty" `Quick test_task_id_to_int_empty
        ; Alcotest.test_case "only prefix" `Quick test_task_id_to_int_only_prefix
        ] )
    ; (* === Archive === *)
      "archive", [ Alcotest.test_case "append tasks" `Quick test_append_archive_tasks ]
    ; (* === RFC-0323 W2: predecessor_task_id === *)
      ( "predecessor"
      , [ Alcotest.test_case "unknown rejected" `Quick test_predecessor_unknown_rejected
        ; Alcotest.test_case
            "non-terminal rejected"
            `Quick
            test_predecessor_non_terminal_rejected
        ; Alcotest.test_case
            "terminal accepted and persisted"
            `Quick
            test_predecessor_terminal_accepted_and_persisted
        ; Alcotest.test_case
            "blank treated as none"
            `Quick
            test_predecessor_blank_treated_as_none
        ; Alcotest.test_case
            "codec absent and malformed"
            `Quick
            test_predecessor_codec_absent_and_malformed
        ] )
    ]
;;
