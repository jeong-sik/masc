(* HIGH-RISK-UNREVIEWED: a model refresh is a call of the operator. This host
   tool publishes its account access after its judgment of the base path, and
   the app-server starts only on an account that access allows (plan D2-6). *)
let authorized ~base_path ~account_home =
  let ( let* ) = Result.bind in
  let* () =
    Runtime_account_access.publish_host_tool ~base_path
      ~config_dir:(Env_config_core.masc_config_dir_opt ())
    |> Result.map_error (fun (first, rest) -> String.concat "; " (first :: rest))
  in
  let* captured = Runtime_official_account.capture ~client:Codex ~declaration:account_home in
  Runtime_account_access.authorize Runtime_account_access.Operator_call
    (Runtime_account_access.seal captured)
  |> Result.map_error Runtime_account_access.refusal_to_string

let run ~base_path ~cli_path ~account_home ~timeout_s =
  let result =
    match authorized ~base_path ~account_home with
    | Error _ as refused -> refused
    | Ok account ->
    try
      let directory = Filename.temp_dir "masc-codex-model-refresh-" "" |> Unix.realpath in
      Fun.protect ~finally:(fun () -> Fs_compat.remove_tree directory) (fun () ->
        Eio_main.run (fun env ->
          Runtime_codex_model_refresh.run ~mgr:(Posix_spawn_process_mgr.foreground_mgr
            ~clock:(Eio.Stdenv.clock env)
            ~grace_seconds:Process_eio.child_exit_grace_seconds)
            ~clock:(Eio.Stdenv.clock env) ~cwd:Eio.Path.(Eio.Stdenv.fs env / directory)
            ~directory ~account ~cli_path ~timeout_s))
    with Sys_error _ | Unix.Unix_error _ -> Error "Codex model refresh could not prepare its private directory."
  in
  match result with
  | Ok json -> print_endline (Yojson.Safe.to_string json); 0
  | Error message -> prerr_endline message; 1
