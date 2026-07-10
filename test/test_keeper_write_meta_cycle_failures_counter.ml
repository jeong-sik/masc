(** #22043: [masc_keeper_write_meta_cycle_failures_total] must count write-meta
    failures only, not every successful persist cycle.

    [Keeper_unified_turn_success.persist_terminal_turn_meta] previously
    incremented [WriteMetaCycleFailures] after the [write_meta_with_merge]
    match rather than inside its [Error] arm, so a successful persist (the
    common case) inflated a [*_failures_total] series that [Dashboard.ml] sums
    into the operator failure panel.

    These tests drive both the success path (write returns [Ok]) and a
    deterministic write failure path (target meta path is a directory). *)

open Alcotest
open Masc

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let ensure_fs env =
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env)

let temp_dir env suffix =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_wmcf_%d_%s" (Unix.getpid ()) suffix)
  in
  if Fs_compat.file_exists dir then Fs_compat.remove_tree dir;
  Eio.Path.mkdirs ~exists_ok:false ~perm:0o755 Eio.Path.(Eio.Stdenv.fs env / dir);
  dir

let cleanup_dir = Fs_compat.remove_tree

let with_temp_dir env suffix f =
  let base_dir = temp_dir env suffix in
  match f base_dir with
  | result ->
    cleanup_dir base_dir;
    result
  | exception exn ->
    let bt = Printexc.get_raw_backtrace () in
    (try cleanup_dir base_dir with
     | cleanup_exn ->
       Printf.eprintf
         "cleanup failed for %S after test failure: %s\n%!"
         base_dir
         (Printexc.to_string cleanup_exn));
    Printexc.raise_with_backtrace exn bt

let make_meta ~name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String ("keeper-" ^ name ^ "-agent"));
          ("trace_id", `String ("trace-" ^ name));
          ("goal", `String "test keeper");
          ("autoboot_enabled", `Bool false);
        ])
  with
  | Ok m -> m
  | Error e -> fail ("meta_of_json failed: " ^ e)

(* Read the exact series+labels production emits at the keeper-cycle site. *)
let cycle_failures_for ~keeper =
  Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string WriteMetaCycleFailures)
    ~labels:
      [ ("keeper", keeper)
      ; ("site", Keeper_write_meta_cycle_failure_site.(to_label Keeper_cycle))
      ]
    ()

let keeper_meta_file config name =
  Filename.concat (Workspace.keepers_runtime_dir config) (name ^ ".json")

let seed_meta_file config m0 =
  match
    Keeper_meta_store.write_meta_with_merge
      ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
      config
      m0
  with
  | Ok () -> ()
  | Error e -> fail ("seed write failed: " ^ e)

let persist_terminal_turn_meta_for_done ~config ~m0 ~active_goal_ids =
  let (_ : Keeper_meta_contract.keeper_meta) =
    Keeper_unified_turn_success.For_testing.persist_terminal_turn_meta_for_outcome
      ~config
      ~original_meta:m0
      ~updated_meta:{ m0 with active_goal_ids }
      ~terminal_outcome:Keeper_unified_turn_success.For_testing.Terminal_done
  in
  ()

let test_success_path_does_not_increment_failures () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  with_temp_dir env "success" (fun base_dir ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let name = "success-cycle" in
      let m0 = make_meta ~name in
      (* Seed the meta file so the merge write has a base version to advance. *)
      seed_meta_file config m0;
      let before = cycle_failures_for ~keeper:name in
      (* Success path: writable temp config -> write_meta returns Ok. *)
      persist_terminal_turn_meta_for_done
        ~config
        ~m0
        ~active_goal_ids:[ "goal-cycle-ok" ];
      let after = cycle_failures_for ~keeper:name in
      check (float 0.0001) "WriteMetaCycleFailures unchanged on success cycle"
        before after)

let test_failure_path_increments_failures () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  with_temp_dir env "failure" (fun base_dir ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let name = "failure-cycle" in
      let m0 = make_meta ~name in
      seed_meta_file config m0;
      let meta_path = keeper_meta_file config name in
      Fs_compat.remove_tree meta_path;
      Eio.Path.mkdirs ~exists_ok:false ~perm:0o755 Eio.Path.(Eio.Stdenv.fs env / meta_path);
      let before = cycle_failures_for ~keeper:name in
      persist_terminal_turn_meta_for_done
        ~config
        ~m0
        ~active_goal_ids:[ "goal-cycle-write-fails" ];
      let after = cycle_failures_for ~keeper:name in
      check (float 0.0001) "WriteMetaCycleFailures increments on failure cycle"
        (before +. 1.0)
        after)

let () =
  run "keeper_write_meta_cycle_failures_counter"
    [ ( "emit_location"
      , [ test_case "success cycle does not inflate failures counter" `Quick
            test_success_path_does_not_increment_failures
        ; test_case "failure cycle increments failures counter" `Quick
            test_failure_path_increments_failures
        ] )
    ]
