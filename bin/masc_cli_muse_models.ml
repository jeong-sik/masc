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
  | Error error -> prerr_endline (Runtime_muse_serve.error_to_string error); 1
