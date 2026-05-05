module Types = Masc_domain

(** Regression test for [Coord_hooks.claim_post_provision_fn] dispatch.

    task-103: a successful [Coord.claim_task_r] must invoke the
    post-provision hook with the same agent_name + task_id, so the keeper
    layer can auto-create a sandbox worktree for docker keepers. The hook
    is best-effort — claim must succeed even when the hook raises. *)

open Alcotest
open Masc_mcp
module CH = Coord_hooks

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
  let config = Coord.default_config tmp_dir in
  let _ = Coord.init config ~agent_name:(Some "claude") in
  let prev = Atomic.get CH.claim_post_provision_fn in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set CH.claim_post_provision_fn prev;
      let _ = Coord.reset config in
      try Unix.rmdir tmp_dir with _ -> ())
    (fun () -> f config)

let test_hook_invoked_on_successful_claim () =
  with_test_env @@ fun config ->
  let calls = ref [] in
  Atomic.set CH.claim_post_provision_fn (fun _ ~agent_name ~task_id ->
      calls := (agent_name, task_id) :: !calls);
  let _ = Coord.add_task config ~title:"task-103 t1" ~priority:1 ~description:"" in
  (match
     Coord.claim_task_r config ~agent_name:"claude" ~task_id:"task-001" ()
   with
   | Ok _ -> ()
   | Error e ->
     fail (Printf.sprintf "claim failed: %s" (Types.show_masc_error e)));
  match !calls with
  | [ (agent_name, task_id) ] ->
    check string "hook agent_name" "claude" agent_name;
    check string "hook task_id" "task-001" task_id
  | other ->
    failf "expected 1 hook call, got %d" (List.length other)

let test_hook_failure_does_not_block_claim () =
  with_test_env @@ fun config ->
  Atomic.set CH.claim_post_provision_fn (fun _ ~agent_name:_ ~task_id:_ ->
      raise (Failure "synthetic worktree provisioning failure"));
  let _ = Coord.add_task config ~title:"task-103 t2" ~priority:1 ~description:"" in
  match
    Coord.claim_task_r config ~agent_name:"claude" ~task_id:"task-001" ()
  with
  | Ok msg ->
    check bool "claim succeeded despite hook failure" true
      (Astring.String.is_infix ~affix:"claimed" msg)
  | Error e ->
    failf "claim must succeed even if hook raises; got: %s"
      (Types.show_masc_error e)

let test_hook_not_invoked_on_already_claimed () =
  with_test_env @@ fun config ->
  let _ = Coord.add_task config ~title:"task-103 t3" ~priority:1 ~description:"" in
  (match
     Coord.claim_task_r config ~agent_name:"claude" ~task_id:"task-001" ()
   with
   | Ok _ -> ()
   | Error e ->
     fail (Printf.sprintf "first claim failed: %s" (Types.show_masc_error e)));
  let calls = ref 0 in
  Atomic.set CH.claim_post_provision_fn (fun _ ~agent_name:_ ~task_id:_ ->
      incr calls);
  let _ = Coord.claim_task_r config ~agent_name:"claude" ~task_id:"task-001" () in
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
          test_case "skips already-claimed repeat" `Quick
            test_hook_not_invoked_on_already_claimed;
        ] );
    ]
