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

let run ~base_path ~assignments =
  let refuse message = prerr_endline message; 1 in
  match changes_of assignments with
  | Error message -> refuse message
  | Ok changes ->
    (match runtime_config_path ~base_path with
     | Error message -> refuse message
     | Ok path ->
       (match Runtime_setting_set.apply ~runtime_config_path:path changes with
        | Error error -> refuse (Runtime_setting_set.error_message error)
        | Ok changed ->
          let keys = String.concat ", " (List.map Runtime_setting_set.toml_key changes) in
          if changed
          then Printf.printf "set %s in %s\n" keys path
          else Printf.printf "%s already as requested in %s\n" keys path;
          if changed && List.exists Runtime_setting_set.requires_restart changes
          then print_endline "A running server reads these when it restarts.";
          0))
