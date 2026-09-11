type error =
  | Private_home_unavailable
  | Command_failed
  | Timed_out
  | Invalid_observation

let error_message = function
  | Private_home_unavailable ->
    "Antigravity's private context observation directory could not be prepared."
  | Command_failed ->
    "Antigravity context observation did not complete. Check the selected account and \
     CLI."
  | Timed_out ->
    "Antigravity did not report its context window before the observation deadline."
  | Invalid_observation ->
    "Antigravity did not report a zero-turn context for the exact selected model and CLI \
     version."
;;

let ( let* ) = Result.bind

let parse_transport ~model ~cli_version body =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string body in
    if json |> member "schema" <> `String "masc.antigravity_status_transport.v1"
    then Error Invalid_observation
    else (
      match json |> member "status" with
      | `String "timed_out" -> Error Timed_out
      | `String "captured" ->
        let rows = json |> member "records" |> to_list in
        if rows = []
        then Error Invalid_observation
        else
          List.fold_left
            (fun result row ->
               let* previous = result in
               let* observed =
                 Runtime_antigravity_setup.parse_context
                   ~model
                   ~cli_version
                   (Yojson.Safe.to_string row)
                 |> Result.map_error (fun _ -> Invalid_observation)
               in
               match previous, observed with
               | Runtime_antigravity_setup.Unknown_context, value
               | value, Runtime_antigravity_setup.Unknown_context -> Ok value
               | Observed_context left, Observed_context right when left = right ->
                 Ok previous
               | Observed_context _, Observed_context _ -> Error Invalid_observation)
            (Ok Runtime_antigravity_setup.Unknown_context)
            rows
      | _ -> Error Command_failed)
  with
  | Yojson.Json_error _ | Type_error _ -> Error Invalid_observation
;;

let measure ~python_path ~cli_path ~timeout_s ~oauth_source ~model runtime_root =
  let* home =
    Runtime_antigravity_home.prepare
      ~runtime_root
      ~owner_leaf:"context-observation"
      ~oauth_source
    |> Result.map_error (fun _ -> Private_home_unavailable)
  in
  let home_dir = Runtime_antigravity_home.home_dir home in
  let script = Filename.concat runtime_root "status-transport.py" in
  let records = Filename.concat runtime_root "status-records.jsonl" in
  let* () =
    try
      Auth.save_private_text_file script Embedded_antigravity_context.script;
      Auth.save_private_text_file records "";
      Ok ()
    with
    | Sys_error _ | Unix.Unix_error _ -> Error Private_home_unavailable
  in
  let invocation = [ python_path; "-I"; "-B"; script ] in
  let command =
    String.concat " " (List.map Filename.quote (invocation @ [ "--capture"; records ]))
  in
  let* () =
    Runtime_antigravity_home.write_context_observation_settings home ~command
    |> Result.map_error (fun _ -> Private_home_unavailable)
  in
  let* () =
    Runtime_antigravity_home.clear_mcp_config home
    |> Result.map_error (fun _ -> Private_home_unavailable)
  in
  let env = Runtime_antigravity.official_client_environment ~home_dir () in
  let key entry =
    match String.index_opt entry '=' with
    | None -> entry
    | Some i -> String.sub entry 0 i
  in
  let env =
    Array.to_list env
    |> List.filter (fun entry ->
      not (List.mem (key entry) [ "TERM"; "TMPDIR"; "TMP"; "TEMP"; "XDG_RUNTIME_DIR" ]))
  in
  let env = Array.of_list ("TERM=xterm-256color" :: ("TMPDIR=" ^ runtime_root) :: env) in
  (* Version exec replaces the transport process in its managed foreground
     group. The Python shim sets cwd even when the native Unix fallback cannot. *)
  let* cli_version =
    match
      Process_eio.run_argv_with_status_split_or_refusal
        ~timeout_sec:timeout_s
        ~env
        ~cwd:home_dir
        (invocation @ [ "--version-probe"; "--home"; home_dir; "--cli"; cli_path ])
    with
    | Ok (Unix.WEXITED 0, stdout, _) when String.trim stdout <> "" ->
      Ok (String.trim stdout)
    | Ok _ | Error _ -> Error Command_failed
  in
  (* The PTY transport itself owns its deadline and kills/reaps its unreaped
     child group before returning. An outer kill timeout could orphan that
     separate session, so do not add one here. *)
  match
    Process_eio.run_argv_with_status_split_or_refusal
      ~env
      ~cwd:home_dir
      (invocation
       @ [ "--home"
         ; home_dir
         ; "--cli"
         ; cli_path
         ; "--model"
         ; model.Runtime_antigravity_setup.id
         ; "--records"
         ; records
         ; "--timeout"
         ; Printf.sprintf "%.17g" timeout_s
         ])
  with
  | Ok (Unix.WEXITED 0, body, _) -> parse_transport ~model ~cli_version body
  | Ok _ | Error _ -> Error Command_failed
;;

let executable_path command =
  let candidates =
    if Filename.is_implicit command
    then
      (match Env_config_core.raw_value_opt "PATH" with
        | Some path -> path
        | None -> "")
      |> String.split_on_char ':'
      |> List.map (fun directory -> Filename.concat directory command)
    else [ command ]
  in
  match
    List.find_map
      (fun path ->
         try
           let path = Unix.realpath path in
           Unix.access path [ Unix.X_OK ];
           if (Unix.stat path).st_kind = Unix.S_REG then Some path else None
         with
         | Unix.Unix_error _ -> None)
      candidates
  with
  | Some path -> Ok path
  | None -> Error Command_failed
;;

let observe ~python_path ~cli_path ~timeout_s ~oauth_source ~model =
  if (not (Float.is_finite timeout_s)) || timeout_s <= 0.
  then Error Command_failed
  else (
    try
      let ( let* ) = Result.bind in
      let* python_path = executable_path python_path in
      let* cli_path = executable_path cli_path in
      let runtime_root =
        Filename.temp_dir "masc-antigravity-context-" "" |> Unix.realpath
      in
      let run () =
        measure ~python_path ~cli_path ~timeout_s ~oauth_source ~model runtime_root
      in
      match Eio_context.get_switch_opt () with
      | None -> Fun.protect ~finally:(fun () -> Fs_compat.remove_tree runtime_root) run
      | Some _ ->
        Eio.Cancel.protect (fun () ->
          Eio.Switch.run (fun sw ->
            Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree runtime_root);
            run ()))
    with
    | Sys_error _ | Unix.Unix_error _ -> Error Private_home_unavailable)
;;

module For_testing = struct
  let parse_transport = parse_transport
end
