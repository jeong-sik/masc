module Types = Masc_domain

(** Regression test for [Workspace_hooks.claim_post_provision_fn] dispatch.

    task-103: a successful [Workspace.claim_task_r] must invoke the
    post-provision hook with the same agent_name + task_id, so the keeper
    layer can auto-create a sandbox worktree for docker keepers. The hook
    is best-effort — claim must succeed even when the hook raises. *)

open Alcotest
open Masc
module CH = Workspace_hooks

let () = Workspace_metric_hooks.install ()

let failure_metric_value ~site ~agent_name =
  Otel_metric_store.metric_value_or_zero
    Otel_metric_store.metric_workspace_claim_post_provision_failures
    ~labels:[ ("site", site); ("agent_name", agent_name) ]
    ()

let with_test_env f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_claim_hook_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir tmp_dir 0o755;
  let config = Workspace.default_config tmp_dir in
  let _ = Workspace.init config ~agent_name:(Some "agent_llm_a") in
  let prev = Atomic.get CH.claim_post_provision_fn in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set CH.claim_post_provision_fn prev;
      let _ = Workspace.reset config in
      try Unix.rmdir tmp_dir with _ -> ())
    (fun () -> f config)

let test_hook_invoked_on_successful_claim () =
  with_test_env @@ fun config ->
  let calls = ref [] in
  Atomic.set CH.claim_post_provision_fn (fun _ ~agent_name ~task_id ->
      calls := (agent_name, task_id) :: !calls);
  let _ = Workspace.add_task config ~title:"task-103 t1" ~priority:1 ~description:"" in
  (match
     Workspace.claim_task_r config ~agent_name:"agent_llm_a" ~task_id:"task-001" ()
   with
   | Ok _ -> ()
   | Error e ->
     fail (Printf.sprintf "claim failed: %s" (Masc_domain.show_masc_error e)));
  match !calls with
  | [ (agent_name, task_id) ] ->
    check string "hook agent_name" "agent_llm_a" agent_name;
    check string "hook task_id" "task-001" task_id
  | other ->
    failf "expected 1 hook call, got %d" (List.length other)

let test_hook_failure_does_not_block_claim () =
  with_test_env @@ fun config ->
  let before = failure_metric_value ~site:"claim_task" ~agent_name:"agent_llm_a" in
  Atomic.set CH.claim_post_provision_fn (fun _ ~agent_name:_ ~task_id:_ ->
      raise (Failure "synthetic worktree provisioning failure"));
  let _ = Workspace.add_task config ~title:"task-103 t2" ~priority:1 ~description:"" in
  match
    Workspace.claim_task_r config ~agent_name:"agent_llm_a" ~task_id:"task-001" ()
  with
  | Ok outcome ->
    check bool "claim succeeded despite hook failure" true
      (Astring.String.is_infix ~affix:"claimed" outcome.message);
    check (float 0.001) "claim failure metric incremented"
      (before +. 1.0)
      (failure_metric_value ~site:"claim_task" ~agent_name:"agent_llm_a")
  | Error e ->
    failf "claim must succeed even if hook raises; got: %s"
      (Masc_domain.show_masc_error e)

let test_claim_next_hook_failure_is_observed () =
  with_test_env @@ fun config ->
  let before = failure_metric_value ~site:"claim_next" ~agent_name:"agent_llm_a" in
  Atomic.set CH.claim_post_provision_fn (fun _ ~agent_name:_ ~task_id:_ ->
      raise (Failure "synthetic claim_next provisioning failure"));
  let _ = Workspace.add_task config ~title:"task-103 t-next" ~priority:1 ~description:"" in
  match Workspace.claim_next_r config ~agent_name:"agent_llm_a" () with
  | Workspace.Claim_next_claimed { task_id; _ } ->
    check string "claimed task" "task-001" task_id;
    check (float 0.001) "claim_next failure metric incremented"
      (before +. 1.0)
      (failure_metric_value ~site:"claim_next" ~agent_name:"agent_llm_a")
  | Workspace.Claim_next_no_unclaimed ->
    fail "claim_next unexpectedly found no unclaimed task"
  | Workspace.Claim_next_no_eligible { excluded_count; _ } ->
    failf "claim_next unexpectedly found no eligible task; excluded=%d"
      excluded_count
  | Workspace.Claim_next_error msg ->
    failf "claim_next unexpectedly failed: %s" msg

let test_claim_next_admission_filter_blocks_claim () =
  with_test_env @@ fun config ->
  let _ = Workspace.add_task config ~title:"admission gated" ~priority:1 ~description:"" in
  let admission_calls = ref 0 in
  let result =
    Workspace.claim_next_r
      config
      ~agent_name:"agent_llm_a"
      ~admission_filter:(fun ~active_tasks:_ task ->
        incr admission_calls;
        not (String.equal task.Masc_domain.id "task-001"))
      ()
  in
  (match result with
   | Workspace.Claim_next_no_eligible { scope_excluded_count; claim_pool_candidate_count; _ } ->
     check int "scope/admission excluded" 1 scope_excluded_count;
     check int "claim pool count" 1 claim_pool_candidate_count
   | Workspace.Claim_next_claimed { task_id; _ } ->
     failf "admission filter should block claim, got %s" task_id
   | Workspace.Claim_next_no_unclaimed ->
     fail "expected no_eligible, got no_unclaimed"
   | Workspace.Claim_next_error msg ->
     failf "claim_next unexpectedly failed: %s" msg);
  check int "admission filter called once" 1 !admission_calls;
  match Workspace.get_tasks_raw config with
  | [ { Masc_domain.task_status = Masc_domain.Todo; _ } ] -> ()
  | _ -> fail "admission-filtered task must remain Todo"

let test_hook_not_invoked_on_already_claimed () =
  with_test_env @@ fun config ->
  let _ = Workspace.add_task config ~title:"task-103 t3" ~priority:1 ~description:"" in
  (match
     Workspace.claim_task_r config ~agent_name:"agent_llm_a" ~task_id:"task-001" ()
   with
   | Ok _ -> ()
   | Error e ->
     fail (Printf.sprintf "first claim failed: %s" (Masc_domain.show_masc_error e)));
  let calls = ref 0 in
  Atomic.set CH.claim_post_provision_fn (fun _ ~agent_name:_ ~task_id:_ ->
      incr calls);
  let _ = Workspace.claim_task_r config ~agent_name:"agent_llm_a" ~task_id:"task-001" () in
  check int "hook does not fire for already_mine repeat" 0 !calls

let () =
  Alcotest.run "claim_post_provision_fn dispatch"
    [
      ( "claim hook",
        [
          test_case "fires on successful first claim" `Quick
            test_hook_invoked_on_successful_claim;
          test_case "does not block claim on hook failure" `Quick
            test_hook_failure_does_not_block_claim;
          test_case "observes claim_next hook failure" `Quick
            test_claim_next_hook_failure_is_observed;
          test_case "admission filter blocks claim_next" `Quick
            test_claim_next_admission_filter_blocks_claim;
          test_case "skips already-claimed repeat" `Quick
            test_hook_not_invoked_on_already_claimed;
        ] );
    ]
