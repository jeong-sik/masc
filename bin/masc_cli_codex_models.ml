let run ~cli_path ~timeout_s =
  let result =
    try
      let directory = Filename.temp_dir "masc-codex-model-refresh-" "" |> Unix.realpath in
      Fun.protect ~finally:(fun () -> Fs_compat.remove_tree directory) (fun () ->
        Eio_main.run (fun env ->
          Runtime_codex_model_refresh.run ~mgr:(Eio.Stdenv.process_mgr env)
            ~clock:(Eio.Stdenv.clock env) ~cwd:Eio.Path.(Eio.Stdenv.fs env / directory)
            ~directory ~cli_path ~timeout_s))
    with Sys_error _ | Unix.Unix_error _ -> Error "Codex model refresh could not prepare its private directory."
  in
  match result with
  | Ok json -> print_endline (Yojson.Safe.to_string json); 0
  | Error message -> prerr_endline message; 1
