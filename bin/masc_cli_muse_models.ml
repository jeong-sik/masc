let run ~cli_path ~account_home ~timeout_s =
  let result =
    try
      let directory = Filename.temp_dir ~perms:0o700 "masc-muse-model-list-" "" |> Unix.realpath in
      Fun.protect ~finally:(fun () -> Fs_compat.remove_tree directory) (fun () ->
        Eio_main.run (fun env ->
          let clock = Eio.Stdenv.clock env in
          let mgr = Posix_spawn_process_mgr.foreground_mgr ~clock
              ~grace_seconds:Process_eio.child_exit_grace_seconds in
          Runtime_muse_model_discovery.run ~mgr ~clock
            ~cwd:Eio.Path.(Eio.Stdenv.fs env / directory)
            ~account_home ~cli_path ~timeout_s))
    with Sys_error _ | Unix.Unix_error _ ->
      Error (Runtime_muse_serve.Invalid_config
        "Muse model discovery could not prepare its private directory")
  in
  match result with
  | Ok json -> print_endline (Yojson.Safe.to_string json); 0
  | Error error ->
    prerr_endline (Runtime_muse_serve.error_to_string error);
    (* Only a typed authentication refusal enters setup sign-in. Native exit 3
       also covers invalid configuration and cannot identify a missing login. *)
    (match error with
     | Runtime_muse_serve.Auth_required _
     | Runtime_muse_serve.Turn_failed {kind=Runtime_muse_msp.Auth_required; _} -> 3
     | Runtime_muse_serve.Turn_failed { kind = (Runtime_muse_msp.Step_limit | (Runtime_muse_msp.Config_error | (Runtime_muse_msp.Projection_error | (Runtime_muse_msp.Log_error | (Runtime_muse_msp.Workflow_launch_error | (Runtime_muse_msp.Environment_error | (Runtime_muse_msp.Model_error | (Runtime_muse_msp.Launch_error | Runtime_muse_msp.Unrecognized_error_kind _))))))));_}
     | Runtime_muse_serve.Session_not_durable | Runtime_muse_serve.Turn_cancelled
     | Runtime_muse_serve.Runtime_shutting_down | Runtime_muse_serve.Invalid_config _
     | Runtime_muse_serve.Spawn_failed _ | Runtime_muse_serve.Turn_input_write_failed _
     | Runtime_muse_serve.Protocol_error _ | Runtime_muse_serve.Rpc_error _
     | Runtime_muse_serve.Capability_not_granted _ | Runtime_muse_serve.Session_model_mismatch _
     | Runtime_muse_serve.Session_workspace_mismatch _
     | Runtime_muse_serve.Session_approval_mode_mismatch _
     | Runtime_muse_serve.Unsupported_server_request _ | Runtime_muse_serve.Process_exited _
     | Runtime_muse_serve.Timeout _ -> 1)
