(** #22043: [masc_keeper_write_meta_cycle_failures_total] must count write-meta
    failures only, not every successful persist cycle.

    [Keeper_unified_turn_success.persist_terminal_turn_meta] previously
    incremented [WriteMetaCycleFailures] after the [write_meta_with_merge]
    match rather than inside its [Error] arm, so a successful persist (the
    common case) inflated a [*_failures_total] series that [Dashboard.ml] sums
    into the operator failure panel.

    This test drives the success path with a writable temp config (write
    returns [Ok]) and asserts the counter does not move. *)

open Alcotest
open Masc

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_wmcf_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let ensure_fs env =
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env)

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

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

let test_success_path_does_not_increment_failures () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let name = "success-cycle" in
      let m0 = make_meta ~name in
      (* Seed the meta file so the merge write has a base version to advance. *)
      (match
         Keeper_meta_store.write_meta_with_merge
           ~merge:Keeper_meta_merge.caller_wins config m0
       with
       | Ok () -> ()
       | Error e -> fail ("seed write failed: " ^ e));
      let before = cycle_failures_for ~keeper:name in
      (* Success path: writable temp config -> write_meta returns Ok. *)
      let (_ : Keeper_meta_contract.keeper_meta) =
        Keeper_unified_turn_success.For_testing.persist_terminal_turn_meta_for_outcome
          ~config
          ~original_meta:m0
          ~updated_meta:{ m0 with continuity_summary = "cycle ok" }
          ~terminal_outcome:Keeper_unified_turn_success.For_testing.Terminal_done
      in
      let after = cycle_failures_for ~keeper:name in
      check (float 0.0001) "WriteMetaCycleFailures unchanged on success cycle"
        before after)

let () =
  run "keeper_write_meta_cycle_failures_counter"
    [ ( "emit_location"
      , [ test_case "success cycle does not inflate failures counter" `Quick
            test_success_path_does_not_increment_failures
        ] )
    ]
