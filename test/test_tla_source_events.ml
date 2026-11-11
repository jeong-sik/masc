open Alcotest
open Masc
module Source = Server_tla_source_events

let write path text = Out_channel.with_open_bin path (fun out -> output_string out text)
let health_status () = match Source.health_json () with
  | `Assoc fields -> List.assoc "status" fields
  | _ -> fail "expected source health object"

let fixture ?inventory_observed ?(directory_observed = fun _ -> ()) f = Eio_main.run (fun env ->
  let root = Filename.temp_dir "tla-source-events-" "" in
  let specs = Filename.concat root "specs" and results = Filename.concat root "results" in
  Unix.mkdir results 0o700;
  let saved_specs = Sys.getenv_opt "MASC_SPECS_DIR" and saved_results = Sys.getenv_opt "MASC_TLC_RESULTS_DIR" in
  Unix.putenv "MASC_SPECS_DIR" specs; Unix.putenv "MASC_TLC_RESULTS_DIR" results;
  let rec cleanup path = match (Unix.lstat path).st_kind with
    | Unix.S_DIR -> Sys.readdir path |> Array.iter (fun name -> cleanup (Filename.concat path name)); Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path in
  let changed = Eio.Condition.create () in
  let specs_count = ref 0 and results_count = ref 0 in
  let remove = Dashboard_observation_commit.subscribe (function
    | Dashboard_observation_commit.Process topic ->
      if topic = `Verification_specs then (incr specs_count; Eio.Condition.broadcast changed)
      else if topic = `Tlc_results then (incr results_count; Eio.Condition.broadcast changed)
    | Dashboard_observation_commit.Workspace _ -> ()) in
  let await predicate =
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0 (fun () ->
      let rec loop () = if not (predicate ()) then (Eio.Condition.await_no_mutex changed; loop ()) in loop ()) in
  Fun.protect ~finally:(fun () ->
    remove ();
    Unix.putenv "MASC_SPECS_DIR" (Option.value ~default:"" saved_specs);
    Unix.putenv "MASC_TLC_RESULTS_DIR" (Option.value ~default:"" saved_results);
    cleanup root) (fun () ->
    let start sw =
      let mono_clock = Eio.Stdenv.mono_clock env in
      let report _ = Eio.Condition.broadcast changed in
      match inventory_observed with
      | None -> Source.start ~sw ~mono_clock ~report
      | Some observed ->
        Source.For_testing.start ~sw ~mono_clock ~report
          ~inventory:(fun () -> observed (); Dashboard_tla_specs.observation_source_inventory ())
          ~after_directory_batch:(fun targets ->
            directory_observed targets;
            Eio.Condition.broadcast changed) in
    f ~root ~specs ~results ~start ~await ~specs_count ~results_count))

let add_spec specs =
  Unix.mkdir specs 0o700;
  let category = Filename.concat specs "boundary" in Unix.mkdir category 0o700;
  let path = Filename.concat category "Observed.tla" in
  write path "MODULE Observed\n";
  write (Filename.concat category "Observed.cfg") "SPECIFICATION Spec\n";
  path

let test_actual_writes_reach_topics () = fixture (fun ~root:_ ~specs ~results ~start ~await ~specs_count ~results_count ->
  let path = add_spec specs in
  Eio.Switch.run (fun sw ->
    start sw;
    await (fun () -> health_status () = `String "ok" && !specs_count > 0 && !results_count > 0);
    let before = !specs_count in
    write path "MODULE Revised\n";
    await (fun () -> !specs_count > before);
    let log = Filename.concat results "tlc-Observed.log" in
    let before = !results_count in
    write log "TLC is starting\n";
    await (fun () -> !results_count > before);
    let before = !results_count in
    write log "Model checking completed. No error has been found.\n";
    await (fun () -> !results_count > before);
    check bool "the unchanged reader observes the written TLC log" true
      (List.exists (fun (row : Dashboard_tla_specs.tlc_result_entry) -> row.status = Dashboard_tla_specs.Tlc_passed)
         (Dashboard_tla_specs.list_tlc_results ())))
  )

let test_dangling_category_recreation () = fixture (fun ~root ~specs ~results:_ ~start ~await ~specs_count ~results_count:_ ->
  Unix.mkdir specs 0o700;
  let target = Filename.concat root "external" in Unix.mkdir target 0o700;
  Unix.symlink target (Filename.concat specs "boundary");
  write (Filename.concat target "Observed.tla") "MODULE Observed\n";
  Eio.Switch.run (fun sw ->
    start sw; await (fun () -> health_status () = `String "ok" && !specs_count > 0);
    let before = !specs_count in
    Unix.rename target (Filename.concat root "retired");
    await (fun () -> !specs_count > before && Dashboard_tla_specs.list_specs () = []);
    let before = !specs_count in
    Unix.mkdir target 0o700;
    write (Filename.concat target "Restored.tla") "MODULE Restored\n";
    await (fun () -> !specs_count > before &&
      List.exists (fun (row : Dashboard_tla_specs.spec_entry) -> row.name = "Restored") (Dashboard_tla_specs.list_specs ())))
  )

let test_failed_source_is_unavailable_then_recovers () = fixture (fun ~root:_ ~specs ~results:_ ~start ~await ~specs_count ~results_count:_ ->
  Unix.symlink specs specs;
  Eio.Switch.run (fun sw ->
    start sw;
    await (fun () -> match Source.health_json () with
      | `Assoc fields -> List.assoc "operator_action_required" fields = `Bool true
      | _ -> false);
    check string "failed observation is unavailable" "unavailable"
      (Yojson.Safe.Util.to_string (health_status ()));
    let rollup = Server_health_rollup.operator_summary
        ~sections:[ "tla_source_observation", Source.health_json () ]
        ~runtime_startup_degradation:(`Assoc []) ~keeper_config_schema_status:"ok"
        ~keeper_config_schema_blocking:false ~keeper_config_schema_terminal_reason:""
        ~keeper_config_operator_action_required:false in
    check string "the real worker failure reaches full-health rollup" "unavailable" rollup.overall_status;
    check bool "the operator sees source observation failure" true rollup.operator_action_required;
    Unix.unlink specs;
    ignore (add_spec specs);
    await (fun () -> health_status () = `String "ok" && !specs_count > 0)))

let test_missing_root_then_rename_recreation () = fixture (fun ~root ~specs ~results:_ ~start ~await ~specs_count ~results_count:_ ->
  Eio.Switch.run (fun sw ->
    start sw; await (fun () -> health_status () = `String "ok" && !specs_count > 0);
    let before = !specs_count in
    ignore (add_spec specs);
    await (fun () -> !specs_count > before && List.length (Dashboard_tla_specs.list_specs ()) = 1);
    let before = !specs_count in
    Unix.rename specs (Filename.concat root "retired");
    await (fun () -> !specs_count > before && Dashboard_tla_specs.list_specs () = []);
    let before = !specs_count in
    ignore (add_spec specs);
    await (fun () -> !specs_count > before && List.length (Dashboard_tla_specs.list_specs ()) = 1)))

let test_unrelated_guard_churn_does_not_rescan_inventory () =
  let scans = Atomic.make 0 in
  let batches = ref [] in
  fixture
    ~inventory_observed:(fun () -> ignore (Atomic.fetch_and_add scans 1))
    ~directory_observed:(fun targets -> batches := targets :: !batches)
    (fun ~root ~specs ~results ~start ~await ~specs_count ~results_count ->
      ignore (add_spec specs);
      Eio.Switch.run (fun sw ->
        start sw;
        await (fun () -> health_status () = `String "ok" && !specs_count > 0 && !results_count > 0);
        let before = Atomic.get scans in
        let await_directory directory =
          let path = Unix.realpath directory in
          await (fun () -> List.exists (fun targets ->
            List.exists (fun (target : Native_file_change.target) -> String.equal target.path path)
              targets) !batches) in
        batches := [];
        write (Filename.concat root "unrelated-ancestor-file") "unrelated";
        await_directory root;
        check int "a processed unrelated ancestor hint does not read the inventory" before (Atomic.get scans);
        batches := [];
        write (Filename.concat results "unrelated-result-file") "unrelated";
        await_directory results;
        check int "a processed unrelated results hint does not read the inventory" before (Atomic.get scans);
        let previous_results = !results_count in
        write (Filename.concat results "tlc-Observed.log")
          "Model checking completed. No error has been found.\n";
        await (fun () -> !results_count > previous_results);
        check bool "a real expected log binding still re-inventories" true (Atomic.get scans > before);
        check bool "the authoritative reader observes the actual log" true
          (List.exists (fun (row : Dashboard_tla_specs.tlc_result_entry) ->
             row.status = Dashboard_tla_specs.Tlc_passed) (Dashboard_tla_specs.list_tlc_results ()))))

let test_ancestor_rename_and_recreation_preserve_coverage () =
  fixture (fun ~root ~specs:_ ~results:_ ~start ~await ~specs_count ~results_count:_ ->
    let ancestor = Filename.concat root "ancestor" in
    let parent = Filename.concat ancestor "parent" in
    let specs = Filename.concat parent "specs" in
    Unix.mkdir ancestor 0o700; Unix.mkdir parent 0o700;
    Unix.putenv "MASC_SPECS_DIR" specs;
    ignore (add_spec specs);
    Eio.Switch.run (fun sw ->
      start sw;
      await (fun () -> health_status () = `String "ok" && !specs_count > 0);
      let before = !specs_count in
      Unix.rename ancestor (Filename.concat root "retired-ancestor");
      await (fun () -> !specs_count > before && Dashboard_tla_specs.list_specs () = []);
      let before = !specs_count in
      Unix.mkdir ancestor 0o700; Unix.mkdir parent 0o700;
      let source = add_spec specs in
      await (fun () -> !specs_count > before && List.length (Dashboard_tla_specs.list_specs ()) = 1);
      let before = !specs_count in
      write source "MODULE Rebound\n";
      await (fun () -> !specs_count > before)))

let test_live_symlink_retarget_preserves_destination_writes () =
  fixture (fun ~root ~specs ~results:_ ~start ~await ~specs_count ~results_count:_ ->
    let first = Filename.concat root "target-a" in
    let second = Filename.concat root "target-b" in
    let first_source = add_spec first in
    let second_source = add_spec second in
    Unix.symlink first specs;
    Eio.Switch.run (fun sw ->
      start sw;
      await (fun () -> health_status () = `String "ok" && !specs_count > 0);
      let before = !specs_count in
      let replacement = Filename.concat root "next-specs-link" in
      Unix.symlink second replacement;
      Unix.rename replacement specs;
      await (fun () -> !specs_count > before);
      check string "the logical root now resolves to the second live target"
        (Unix.realpath second) (Unix.realpath specs);
      check bool "the original source still exists" true (Sys.file_exists first_source);
      check bool "the replacement source already existed" true (Sys.file_exists second_source);
      let before = !specs_count in
      write second_source "MODULE Retargeted\n";
      await (fun () -> !specs_count > before)))

let () = run "tla_source_events" [ "source_to_hook", [
  test_case "actual spec and in-place TLC writes reach typed topics" `Quick test_actual_writes_reach_topics;
  test_case "dangling category target recreation resumes observation" `Quick test_dangling_category_recreation;
  test_case "failed observation is unavailable until recovery" `Quick test_failed_source_is_unavailable_then_recovers;
  test_case "missing root and renamed root recover through ancestors" `Quick test_missing_root_then_rename_recreation;
  test_case "unrelated processed guard hints skip full inventory" `Quick test_unrelated_guard_churn_does_not_rescan_inventory;
  test_case "ancestor rename and recreation preserve observation" `Quick test_ancestor_rename_and_recreation_preserve_coverage;
  test_case "live symlink retarget observes subsequent destination writes" `Quick test_live_symlink_retarget_preserves_destination_writes;
] ]
