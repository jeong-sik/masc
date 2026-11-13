let parse_assignment raw =
  match String.index_opt raw '=' with
  | None -> Error (Printf.sprintf "%S is not KEY=VALUE" raw)
  | Some 0 -> Error (Printf.sprintf "%S has no key before the =" raw)
  | Some at ->
    Ok (String.sub raw 0 at, String.sub raw (at + 1) (String.length raw - at - 1))

let changes_of assignments =
  let rec collect parsed = function
    | [] -> Ok (List.rev parsed)
    | raw :: rest ->
      (match parse_assignment raw with
       | Error message -> Error message
       | Ok (key, value) ->
         (match Runtime_setting_set.parse ~key ~value with
          | Error error -> Error (Runtime_setting_set.error_message error)
          | Ok change -> collect (change :: parsed) rest))
  in
  collect [] assignments

(* The file the server reads: [MASC_CONFIG_DIR] first, then the workspace's own
   [.masc/config]. A workspace that has none yet is seeded the way server start
   seeds it, so a script can set a key before its first start. One that has a
   file is left alone: seeding an existing root also refills prompt seeds and
   the like, which is a start's business and not the write of one key. *)
let runtime_config_path ~base_path =
  let path_of () = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
  if Sys.file_exists (path_of ())
  then Ok (path_of ())
  else (
    Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path;
    let path = path_of () in
    if Sys.file_exists path
    then Ok path
    else
      Error
        (Printf.sprintf
           "%s does not exist, and seeding the config root did not create it. Boot \
            writes nothing when MASC_CONFIG_DIR is set or MASC_CONFIG_BOOTSTRAP is \
            skip or empty."
           path))

let report_local ~path ~changed changes =
  let keys = String.concat ", " (List.map Runtime_setting_set.toml_key changes) in
  if changed
  then Printf.printf "set %s in %s\n" keys path
  else Printf.printf "%s already as requested in %s\n" keys path

(* With no process holding the workspace lease, the command writes the file
   itself: then nothing else writes it and no reader is waiting to be told. *)
let write_locally ~refuse ~base_path changes =
  match runtime_config_path ~base_path with
  | Error message -> refuse message
  | Ok path ->
    (match Runtime_setting_set.apply ~runtime_config_path:path changes with
     | Error error -> refuse (Runtime_setting_set.error_message error)
     | Ok changed ->
       report_local ~path ~changed changes;
       if changed && List.exists Runtime_setting_set.requires_restart changes
       then print_endline "A running server reads these when it restarts.";
       0)

let report_server ~outcome changes =
  let keys = String.concat ", " (List.map Runtime_setting_set.toml_key changes) in
  match outcome with
  | Masc_cli_runtime_config_remote.Unchanged ->
    Printf.printf "%s already as requested in the running server's runtime.toml\n" keys
  | Masc_cli_runtime_config_remote.Saved { path } ->
    Printf.printf "set %s in %s through the running server\n" keys path;
    if List.exists Runtime_setting_set.requires_restart changes
    then print_endline "The running server applies these when it restarts."

let run ~base_path ~port ~agent ~assignments =
  let refuse message = prerr_endline message; 1 in
  match changes_of assignments with
  | Error message -> refuse message
  | Ok changes ->
    (match Unix.realpath base_path with
     | exception Unix.Unix_error _ ->
       (* A workspace that does not exist yet has no server; seeding it is
          this command's to do. *)
       write_locally ~refuse ~base_path changes
     | real_base_path ->
       let route =
         Masc_cli_runtime_config_remote.with_client (fun ~clock ->
           match Masc_cli_runtime_config_remote.find ~clock ~base_path:real_base_path ~port ~agent with
           | Error message -> `Refused message
           | Ok Masc_cli_runtime_config_remote.No_server -> `Local
           | Ok (Masc_cli_runtime_config_remote.Running_server server) ->
             (* RFC-0482 §3.2: the running server is the writer. *)
             let edit text =
               Result.map_error Runtime_setting_set.error_message
                 (Runtime_setting_set.edit_text changes text)
             in
             `Through_server (Masc_cli_runtime_config_remote.save ~clock server ~edit))
       in
       (match route with
        | `Refused message -> refuse message
        | `Local -> write_locally ~refuse ~base_path changes
        | `Through_server (Error message) -> refuse message
        | `Through_server (Ok outcome) ->
          report_server ~outcome changes;
          0))
