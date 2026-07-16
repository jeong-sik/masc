open Alcotest
open Masc

let () =
  Server_startup_state.mark_state_ready
    ~backend:Server_startup_state.Filesystem_backend
  |> Result.get_ok

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "agent_name", `String (name ^ "-agent")
        ; "trace_id", `String (name ^ "-trace")
        ; "allowed_paths", `List [ `String "*" ]
        ])
  with
  | Ok meta -> meta
  | Error detail -> failf "meta fixture failed: %s" detail

let persisted_meta_exn config name =
  match Keeper_meta_store.read_meta config name with
  | Ok (Some meta) -> meta
  | Ok None -> fail "persisted keeper meta is missing"
  | Error detail -> failf "persisted keeper meta read failed: %s" detail

let test_missing_checkpoint_still_queues_owner_lane_stimulus () =
  Eio_main.run @@ fun env ->
  Masc_test_deps.ensure_rng_initialized ();
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  let keeper_name = "compact-missing-checkpoint" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.unregister ~base_path keeper_name;
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      let config = Workspace.default_config base_path in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let runtime_path =
        Filename.concat (Masc_test_deps.find_project_root ()) "config/runtime.toml"
      in
      Result.get_ok (Runtime.init_default ~config_path:runtime_path);
      let meta = make_meta keeper_name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error detail -> failf "keeper meta write failed: %s" detail);
      let persisted_meta = persisted_meta_exn config keeper_name in
      ignore
        (Keeper_registry.register
           ~base_path:config.base_path
           keeper_name
           persisted_meta);
      let ctx : _ Keeper_tool_surface.context =
        { config
        ; agent_name = "operator"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = None
        ; net = None
        ; publication_recovery_provider =
            Masc_test_deps.non_runtime_publication_recovery_provider
        }
      in
      match
        Keeper_tool_surface.dispatch
          ctx
          ~name:"masc_keeper_compact"
          ~args:(`Assoc [ "name", `String keeper_name ])
      with
      | None -> fail "masc_keeper_compact is not registered"
      | Some (Tool_result.Deferred _) -> fail "compaction admission must not defer"
      | Some (Tool_result.Failed failure) ->
        failf "compaction admission must queue, got failure: %s" failure.message
      | Some (Tool_result.Completed output) ->
        (* #24598 (RFC-0182 §3.1): the tool surface only queues a
           Manual_compaction_requested stimulus on the owner lane; the
           checkpoint lookup and its typed recovery failure now surface
           when the lane consumes the stimulus, not at dispatch. *)
        check string "tool identity" "masc_keeper_compact" output.tool_name;
        check bool "admission acknowledges queueing" true
          Yojson.Safe.Util.(output.data |> member "queued" |> to_bool);
        check string "owner-lane stimulus kind" "manual_compaction_requested"
          Yojson.Safe.Util.(output.data |> member "stimulus" |> to_string);
        check bool "queue outcome is reported" true
          Yojson.Safe.Util.(
            output.data |> member "queue_outcome" |> to_string <> ""))

let () =
  run "keeper_compact_recovery_tool_surface"
    [ ( "recovery_failure"
      , [ test_case
            "missing checkpoint still queues the owner-lane stimulus"
            `Quick
            test_missing_checkpoint_still_queues_owner_lane_stimulus
        ] )
    ]
