type t =
  { docker_args : string list
  ; cleanup : unit -> unit
  }

type source_kind =
  | Env_source
  | File_source

type secret_root_info =
  { root : string
  ; source : string
  }

let trim_env_opt key =
  match Sys.getenv_opt key with
  | Some value ->
    let trimmed = String.trim value in
    if String.equal trimmed "" then None else Some trimmed
  | None -> None
;;

let secret_root_info ~base_path ~keeper_name =
  let keeper_dir = Workspace_utils.safe_filename keeper_name in
  match trim_env_opt "MASC_SECRET_DIR" with
  | Some root -> { root = Filename.concat root keeper_dir; source = "MASC_SECRET_DIR" }
  | None ->
    { root =
        Filename.concat
          (Filename.concat (Common.masc_dir_from_base_path ~base_path) "secrets")
          keeper_dir
    ; source = "workspace_masc_secrets"
    }
;;

let secret_root ~base_path ~keeper_name =
  (secret_root_info ~base_path ~keeper_name).root
;;

let path_exists path =
  try Sys.file_exists path with
  | Sys_error _ -> false
;;

let is_directory path =
  try Sys.is_directory path with
  | Sys_error _ -> false
;;

let list_dir_sorted path =
  try Ok (Sys.readdir path |> Array.to_list |> List.sort String.compare) with
  | Sys_error msg -> Error msg
;;

let lstat path =
  try Ok (Unix.lstat path) with
  | Unix.Unix_error (err, fn, arg) ->
    Error
      (Printf.sprintf
         "%s%s%s"
         (Unix.error_message err)
         (if String.equal fn "" then "" else ": " ^ fn)
         (if String.equal arg "" then "" else " " ^ arg))
;;

let source_label = function
  | Env_source -> "env"
  | File_source -> "files"
;;

let reject_symlink ~kind path =
  match lstat path with
  | Error err -> Error err
  | Ok st ->
    (match st.Unix.st_kind with
     | Unix.S_LNK ->
       Error
         (Printf.sprintf
            "keeper secret %s entry must not be a symlink: %s"
            (source_label kind)
            path)
     | _ -> Ok st)
;;

let valid_env_name name =
  let len = String.length name in
  let valid_first = function
    | 'A' .. 'Z' | 'a' .. 'z' | '_' -> true
    | _ -> false
  in
  let valid_rest = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  len > 0
  && valid_first name.[0]
  &&
  let rec loop i =
    if i = len then true else valid_rest name.[i] && loop (i + 1)
  in
  loop 1
;;

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)
;;

let strip_one_final_newline value =
  let len = String.length value in
  if len >= 2 && Char.equal value.[len - 2] '\r' && Char.equal value.[len - 1] '\n'
  then String.sub value 0 (len - 2)
  else if len >= 1 && (Char.equal value.[len - 1] '\n' || Char.equal value.[len - 1] '\r')
  then String.sub value 0 (len - 1)
  else value
;;

let contains_char value c =
  String.contains value c
;;

let read_env_entry path =
  try
    let value = read_file path |> strip_one_final_newline in
    if contains_char value '\n' || contains_char value '\r'
    then Error (Printf.sprintf "keeper secret env value must be single-line: %s" path)
    else if contains_char value '\000'
    then Error (Printf.sprintf "keeper secret env value must not contain NUL: %s" path)
    else if String.length value > 0 && Char.equal value.[0] '#'
    then
      Error
        (Printf.sprintf
           "keeper secret env value must not start with '#', which docker --env-file \
            treats as a comment: %s"
           path)
    else Ok value
  with
  | Sys_error msg -> Error msg
;;

let load_env_entries env_root =
  if not (path_exists env_root)
  then Ok []
  else if not (is_directory env_root)
  then Error (Printf.sprintf "keeper secret env path is not a directory: %s" env_root)
  else (
    match reject_symlink ~kind:Env_source env_root with
    | Error _ as err -> err
    | Ok _ ->
    (match list_dir_sorted env_root with
     | Error err -> Error err
     | Ok names ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | name :: rest ->
          if not (valid_env_name name)
          then Error (Printf.sprintf "invalid keeper secret env name: %s" name)
          else
            let path = Filename.concat env_root name in
            (match reject_symlink ~kind:Env_source path with
             | Error _ as err -> err
             | Ok st ->
               (match st.Unix.st_kind with
                | Unix.S_REG ->
                  (match read_env_entry path with
                   | Error _ as err -> err
                   | Ok value -> loop ((name, value) :: acc) rest)
                | _ ->
                  Error
                    (Printf.sprintf
                       "keeper secret env entry must be a regular file: %s"
                       path)))
      in
      loop [] names))
;;

let env_key entry =
  match String.index_opt entry '=' with
  | None -> entry
  | Some idx -> String.sub entry 0 idx
;;

let flattened_env_entries entries =
  List.map (fun (name, value) -> name ^ "=" ^ value) entries
;;

let overlay_env_entries base entries =
  let overrides = flattened_env_entries entries in
  let override_keys = List.map fst entries in
  let inherited =
    base
    |> Array.to_list
    |> List.filter (fun entry -> not (List.mem (env_key entry) override_keys))
  in
  Array.of_list (inherited @ overrides)
;;

(* Prevent [gh] from falling back to the operator's HOME/XDG config when the
   keeper supplies token env credentials but no explicit GH_CONFIG_DIR. *)
let local_empty_gh_config_dir = "/var/empty"

let env_entries_have key entries =
  List.exists (fun (name, _) -> String.equal name key) entries
;;

let local_env_entries_with_defaults entries =
  if env_entries_have "GH_CONFIG_DIR" entries
     || not (path_exists local_empty_gh_config_dir && is_directory local_empty_gh_config_dir)
  then entries
  else ("GH_CONFIG_DIR", local_empty_gh_config_dir) :: entries
;;

let local_base_host_env ?host_env () =
  let base =
    match host_env with
    | Some env -> env
    | None -> Unix.environment ()
  in
  base
  |> Env_keeper_scrub.filter_environment
  |> Env_git_noninteractive.inject_into_environment
;;

let valid_rel_component component =
  not
    (String.equal component ""
     || String.equal component "."
     || String.equal component ".."
     || contains_char component '/')
;;

let container_path_of_rel rel =
  "/" ^ String.concat "/" rel
;;

let collect_file_entries files_root =
  let rec walk rel host_dir acc =
    match reject_symlink ~kind:File_source host_dir with
    | Error _ as err -> err
    | Ok st ->
      (match st.Unix.st_kind with
       | Unix.S_DIR ->
         (match list_dir_sorted host_dir with
          | Error err -> Error err
          | Ok names ->
            let rec loop acc = function
              | [] -> Ok acc
              | name :: rest ->
                if not (valid_rel_component name)
                then
                  Error
                    (Printf.sprintf "invalid keeper secret file path component: %s" name)
                else (
                  match walk (rel @ [ name ]) (Filename.concat host_dir name) acc with
                  | Error _ as err -> err
                  | Ok acc -> loop acc rest)
            in
            loop acc names)
       | Unix.S_REG ->
         if rel = []
         then Error (Printf.sprintf "keeper secret files root is not a directory: %s" files_root)
         else Ok ((host_dir, container_path_of_rel rel) :: acc)
       | Unix.S_LNK ->
         Error
           (Printf.sprintf "keeper secret file entry must not be a symlink: %s" host_dir)
       | _ ->
         Error
           (Printf.sprintf
              "keeper secret file entry must be a regular file or directory: %s"
              host_dir))
  in
  if not (path_exists files_root)
  then Ok []
  else if not (is_directory files_root)
  then Error (Printf.sprintf "keeper secret files path is not a directory: %s" files_root)
  else
    match walk [] files_root [] with
    | Error _ as err -> err
    | Ok entries -> Ok (List.rev entries)
;;

let json_string_list values =
  `List (List.map (fun value -> `String value) values)
;;

let file_mount_json (host_path, container_path) =
  `Assoc [ "host_path", `String host_path; "container_path", `String container_path ]
;;

let status_json
      ~root
      ~source
      ~status
      ~configured
      ~env_names
      ~file_entries
      ~error
      ~next_action
  =
  `Assoc
    [ "status", `String status
    ; "configured", `Bool configured
    ; "root", `String root
    ; "source", `String source
    ; "env_count", `Int (List.length env_names)
    ; "file_count", `Int (List.length file_entries)
    ; "env_names", json_string_list env_names
    ; "file_mounts", `List (List.map file_mount_json file_entries)
    ; "values_validated", `Bool true
    ; "error", (match error with Some err -> `String err | None -> `Null)
    ; "next_action", `String next_action
    ]
;;

let dashboard_status_json ~base_path ~keeper_name =
  let { root; source } = secret_root_info ~base_path ~keeper_name in
  if not (path_exists root)
  then
    status_json
      ~root
      ~source
      ~status:"absent"
      ~configured:false
      ~env_names:[]
      ~file_entries:[]
      ~error:None
      ~next_action:("create " ^ root ^ "/env and/or " ^ root ^ "/files")
  else if not (is_directory root)
  then
    status_json
      ~root
      ~source
      ~status:"error"
      ~configured:true
      ~env_names:[]
      ~file_entries:[]
      ~error:(Some ("keeper secret root is not a directory: " ^ root))
      ~next_action:"replace the secret root with a directory"
  else (
    match reject_symlink ~kind:File_source root with
    | Error err ->
      status_json
        ~root
        ~source
        ~status:"error"
        ~configured:true
        ~env_names:[]
        ~file_entries:[]
        ~error:(Some err)
        ~next_action:"replace the secret root symlink with a real directory"
    | Ok _ ->
      let env_root = Filename.concat root "env" in
      let files_root = Filename.concat root "files" in
      (match load_env_entries env_root with
       | Error err ->
         status_json
           ~root
           ~source
           ~status:"error"
           ~configured:true
           ~env_names:[]
           ~file_entries:[]
           ~error:(Some err)
           ~next_action:"fix keeper secret env entries"
       | Ok env_entries ->
         (match collect_file_entries files_root with
          | Error err ->
            status_json
              ~root
              ~source
              ~status:"error"
              ~configured:true
              ~env_names:(List.map fst env_entries)
              ~file_entries:[]
              ~error:(Some err)
              ~next_action:"fix keeper secret file entries"
          | Ok file_entries ->
            let status =
              if env_entries = [] && file_entries = [] then "empty" else "ready"
            in
            let next_action =
              if String.equal status "ready"
              then "none"
              else "add entries under env/ and/or files/"
            in
            status_json
              ~root
              ~source
              ~status
              ~configured:true
              ~env_names:(List.map fst env_entries)
              ~file_entries
              ~error:None
              ~next_action)))
;;

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" || Sys.file_exists path
  then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    try Unix.mkdir path 0o700 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let private_tmp_dir ~base_path =
  let dir = Filename.concat (Common.masc_dir_from_base_path ~base_path) "tmp" in
  ensure_dir dir;
  if not (Sys.is_directory dir)
  then
    raise
      (Failure
         (Printf.sprintf "keeper private tmp path is not a directory: %s" dir));
  dir
;;

let write_env_file ~base_path ~container_name entries =
  if entries = []
  then Ok None
  else
    let tmp_dir = private_tmp_dir ~base_path in
    let prefix =
      "masc_keeper_secret_env_"
      ^ Workspace_utils.safe_filename container_name
      ^ "_"
    in
    try
      let path, oc =
        Filename.open_temp_file
          ~temp_dir:tmp_dir
          ~mode:[ Open_wronly; Open_binary ]
          ~perms:0o600
          prefix
          ".env"
      in
      try
        Fun.protect
          ~finally:(fun () -> close_out_noerr oc)
          (fun () ->
             List.iter
               (fun (name, value) ->
                  output_string oc name;
                  output_char oc '=';
                  output_string oc value;
                  output_char oc '\n')
               entries);
        Ok (Some path)
      with
      | exn ->
        (try if Sys.file_exists path then Sys.remove path with
         | Sys_error _ | Unix.Unix_error _ -> ());
        raise exn
    with
    | Sys_error msg -> Error msg
    | Unix.Unix_error (err, fn, arg) ->
      Error
        (Printf.sprintf
           "%s%s%s"
           (Unix.error_message err)
           (if String.equal fn "" then "" else ": " ^ fn)
           (if String.equal arg "" then "" else " " ^ arg))
;;

let cleanup_files paths =
  List.iter
    (fun path ->
       try if Sys.file_exists path then Sys.remove path with
       | Sys_error _ | Unix.Unix_error _ -> ())
    paths
;;

let local_env_for_keeper ?host_env ~base_path ~keeper_name () =
  let root = secret_root ~base_path ~keeper_name in
  if not (path_exists root)
  then
    let env_entries = local_env_entries_with_defaults [] in
    Ok (Some (overlay_env_entries (local_base_host_env ?host_env ()) env_entries))
  else if not (is_directory root)
  then Error (Printf.sprintf "keeper secret root is not a directory: %s" root)
  else (
    match reject_symlink ~kind:File_source root with
    | Error _ as err -> err
    | Ok _ ->
      let env_root = Filename.concat root "env" in
      let files_root = Filename.concat root "files" in
      (match load_env_entries env_root with
       | Error _ as err -> err
       | Ok env_entries ->
	         (match collect_file_entries files_root with
	          | Error _ as err -> err
	          | Ok _file_entries ->
	            let env_entries = local_env_entries_with_defaults env_entries in
	            let base = local_base_host_env ?host_env () in
	            Ok (Some (overlay_env_entries base env_entries)))))
;;

let docker_args_for_keeper ~base_path ~keeper_name ~container_name =
  let root = secret_root ~base_path ~keeper_name in
  if not (path_exists root)
  then Ok { docker_args = []; cleanup = (fun () -> ()) }
  else if not (is_directory root)
  then Error (Printf.sprintf "keeper secret root is not a directory: %s" root)
  else (
    match reject_symlink ~kind:File_source root with
    | Error _ as err -> err
    | Ok _ ->
      let env_root = Filename.concat root "env" in
      let files_root = Filename.concat root "files" in
      (match load_env_entries env_root with
       | Error _ as err -> err
       | Ok env_entries ->
         (match collect_file_entries files_root with
          | Error _ as err -> err
          | Ok file_entries ->
            (match write_env_file ~base_path ~container_name env_entries with
             | Error _ as err -> err
             | Ok env_file ->
               let env_args =
                 match env_file with
                 | None -> []
                 | Some path -> [ "--env-file"; path ]
               in
               let file_args =
                 file_entries
                 |> List.concat_map (fun (host, container) ->
                   [ "-v"; host ^ ":" ^ container ^ ":ro" ])
               in
               let cleanup =
                 match env_file with
                 | None -> fun () -> ()
                 | Some path -> fun () -> cleanup_files [ path ]
               in
               Ok { docker_args = env_args @ file_args; cleanup }))))
;;
