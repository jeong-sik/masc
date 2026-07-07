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

type secret_scope =
  | Shared_secret
  | Keeper_secret

type loaded_secret_root =
  { info : secret_root_info
  ; configured : bool
  ; env_entries : (string * string) list
  ; file_entries : (string * string) list
  }

let base_secret_scope = "base"

let trim_env_opt key =
  match Sys.getenv_opt key with
  | Some value ->
    let trimmed = String.trim value in
    if String.equal trimmed "" then None else Some trimmed
  | None -> None
;;

let secret_root_info_of_dir ~base_path ~keeper_dir =
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

let keeper_secret_dir keeper_name = Workspace_utils.safe_filename keeper_name

let secret_root_info ~base_path ~keeper_name =
  secret_root_info_of_dir ~base_path ~keeper_dir:(keeper_secret_dir keeper_name)
;;

let secret_root ~base_path ~keeper_name =
  (secret_root_info ~base_path ~keeper_name).root
;;

let base_secret_root_info ~base_path =
  secret_root_info_of_dir ~base_path ~keeper_dir:base_secret_scope
;;

let secret_roots ~base_path ~keeper_name =
  let keeper_dir = keeper_secret_dir keeper_name in
  let keeper_root = secret_root_info_of_dir ~base_path ~keeper_dir in
  if String.equal keeper_dir base_secret_scope
  then [ keeper_root ]
  else [ base_secret_root_info ~base_path; keeper_root ]
;;

let secret_root_info_for_scope ~base_path ~keeper_name = function
  | Shared_secret -> base_secret_root_info ~base_path
  | Keeper_secret -> secret_root_info ~base_path ~keeper_name
;;

let secret_scope_of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "shared" | "base" -> Some Shared_secret
  | "keeper" -> Some Keeper_secret
  | _ -> None
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

let validate_env_value ~path value =
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
;;

let read_env_entry path =
  try
    let value = read_file path |> strip_one_final_newline in
    validate_env_value ~path value
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

let load_secret_root info =
  let root = info.root in
  if not (path_exists root)
  then Ok { info; configured = false; env_entries = []; file_entries = [] }
  else if not (is_directory root)
  then Error (Printf.sprintf "keeper secret root is not a directory: %s" root)
  else
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
            Ok { info; configured = true; env_entries; file_entries }))
;;

let load_secret_roots ~base_path ~keeper_name =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | info :: rest ->
      (match load_secret_root info with
       | Error _ as err -> err
       | Ok loaded -> loop (loaded :: acc) rest)
  in
  loop [] (secret_roots ~base_path ~keeper_name)
;;

let overlay_by_key key_of base overlay =
  let overlay_keys = List.map key_of overlay in
  base |> List.filter (fun item -> not (List.mem (key_of item) overlay_keys)) |> fun base ->
  base @ overlay
;;

let merge_env_entries roots =
  List.fold_left
    (fun acc loaded -> overlay_by_key fst acc loaded.env_entries)
    []
    roots
;;

let merge_file_entries roots =
  List.fold_left
    (fun acc loaded -> overlay_by_key snd acc loaded.file_entries)
    []
    roots
;;

let any_configured roots = List.exists (fun loaded -> loaded.configured) roots

let json_string_list values =
  `List (List.map (fun value -> `String value) values)
;;

let file_mount_json (host_path, container_path) =
  `Assoc [ "host_path", `String host_path; "container_path", `String container_path ]
;;

let secret_root_json loaded =
  let status =
    if not loaded.configured
    then "absent"
    else if loaded.env_entries = [] && loaded.file_entries = []
    then "empty"
    else "ready"
  in
  `Assoc
    [ "root", `String loaded.info.root
    ; "source", `String loaded.info.source
    ; "status", `String status
    ; "configured", `Bool loaded.configured
    ; "env_count", `Int (List.length loaded.env_entries)
    ; "file_count", `Int (List.length loaded.file_entries)
    ]
;;

let status_json
      ~root
      ~source
      ~effective_roots
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
    ; "effective_roots", `List (List.map secret_root_json effective_roots)
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
  match load_secret_roots ~base_path ~keeper_name with
  | Error err ->
    status_json
      ~root
      ~source
      ~effective_roots:[]
      ~status:"error"
      ~configured:true
      ~env_names:[]
      ~file_entries:[]
      ~error:(Some err)
      ~next_action:"fix keeper secret roots"
  | Ok roots ->
    let env_entries = merge_env_entries roots in
    let file_entries = merge_file_entries roots in
    let status =
      if not (any_configured roots)
      then "absent"
      else if env_entries = [] && file_entries = []
      then "empty"
      else "ready"
    in
    let next_action =
      match status with
      | "ready" -> "none"
      | "absent" ->
        "create "
        ^ root
        ^ "/env and/or "
        ^ root
        ^ "/files, or configure "
        ^ (base_secret_root_info ~base_path).root
      | _ -> "add entries under env/ and/or files/"
    in
    status_json
      ~root
      ~source
      ~effective_roots:roots
      ~status
      ~configured:(any_configured roots)
      ~env_names:(List.map fst env_entries)
      ~file_entries
      ~error:None
      ~next_action
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

let unix_error_message err fn arg =
  Printf.sprintf
    "%s%s%s"
    (Unix.error_message err)
    (if String.equal fn "" then "" else ": " ^ fn)
    (if String.equal arg "" then "" else " " ^ arg)
;;

let ensure_secret_directory ~label path =
  try
    ensure_dir path;
    if not (is_directory path)
    then Error (Printf.sprintf "keeper secret %s path is not a directory: %s" label path)
    else (
      match lstat path with
      | Error _ as err -> err
      | Ok st ->
        (match st.Unix.st_kind with
         | Unix.S_LNK ->
           Error
             (Printf.sprintf
                "keeper secret %s path must not be a symlink: %s"
                label
                path)
         | _ -> Ok ()))
  with
  | Sys_error msg -> Error msg
  | Unix.Unix_error (err, fn, arg) -> Error (unix_error_message err fn arg)
;;

let validate_env_entry_target path =
  try
    let st = Unix.lstat path in
    match st.Unix.st_kind with
    | Unix.S_REG -> Ok ()
    | Unix.S_LNK ->
      Error
        (Printf.sprintf "keeper secret env entry must not be a symlink: %s" path)
    | _ ->
      Error
        (Printf.sprintf
           "keeper secret env entry must be a regular file: %s"
           path)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | Unix.Unix_error (err, fn, arg) -> Error (unix_error_message err fn arg)
;;

let reject_base_keeper_scope_mutation ~keeper_name ~scope =
  if String.equal keeper_name "base" && scope = Keeper_secret
  then Error "keeper-scope secret mutation is not permitted for the reserved 'base' keeper"
  else Ok ()
;;

let set_env_entry ~base_path ~keeper_name ~scope ~name ~value =
  match reject_base_keeper_scope_mutation ~keeper_name ~scope with
  | Error _ as err -> err
  | Ok () ->
    let name = String.trim name in
    if not (valid_env_name name)
    then Error (Printf.sprintf "invalid keeper secret env name: %s" name)
    else
      let value = strip_one_final_newline value in
      match validate_env_value ~path:name value with
      | Error _ as err -> err
      | Ok value ->
        let info = secret_root_info_for_scope ~base_path ~keeper_name scope in
        let env_root = Filename.concat info.root "env" in
        (match ensure_secret_directory ~label:"root" info.root with
         | Error _ as err -> err
         | Ok () ->
           (match ensure_secret_directory ~label:"env" env_root with
            | Error _ as err -> err
            | Ok () ->
              let path = Filename.concat env_root name in
              (match validate_env_entry_target path with
               | Error _ as err -> err
               | Ok () ->
                 (match Fs_compat.save_file_atomic path value with
                  | Error _ as err -> err
                  | Ok () ->
                    (try
                       Unix.chmod path 0o600;
                       Ok ()
                     with
                     | Unix.Unix_error (err, fn, arg) ->
                       Error (unix_error_message err fn arg))))))
;;

let delete_env_entry ~base_path ~keeper_name ~scope ~name =
  match reject_base_keeper_scope_mutation ~keeper_name ~scope with
  | Error _ as err -> err
  | Ok () ->
    let name = String.trim name in
    if not (valid_env_name name)
    then Error (Printf.sprintf "invalid keeper secret env name: %s" name)
    else
      let info = secret_root_info_for_scope ~base_path ~keeper_name scope in
    if not (path_exists info.root)
    then Ok ()
    else
      match ensure_secret_directory ~label:"root" info.root with
      | Error _ as err -> err
      | Ok () ->
        let env_root = Filename.concat info.root "env" in
        if not (path_exists env_root)
        then Ok ()
        else (
          match ensure_secret_directory ~label:"env" env_root with
          | Error _ as err -> err
          | Ok () ->
            let path = Filename.concat env_root name in
            (match validate_env_entry_target path with
             | Error _ as err -> err
             | Ok () ->
               (try
                  if path_exists path then Sys.remove path;
                  Ok ()
                with
                | Sys_error msg -> Error msg
                | Unix.Unix_error (err, fn, arg) ->
                  Error (unix_error_message err fn arg))))
;;

let file_rel_components_of_container_path container_path =
  let path = String.trim container_path in
  if String.equal path ""
  then Error "keeper secret file path is required"
  else if contains_char path '\000'
  then Error "keeper secret file path must not contain NUL"
  else if not (String.starts_with ~prefix:"/" path)
  then Error "keeper secret file path must be absolute"
  else
    let components =
      match String.split_on_char '/' path with
      | "" :: rest -> rest
      | parts -> parts
    in
    if components = []
    then Error "keeper secret file path must not be root"
    else
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | component :: rest ->
          if not (valid_rel_component component)
          then
            Error
              (Printf.sprintf
                 "invalid keeper secret file path component: %s"
                 component)
          else loop (component :: acc) rest
      in
      loop [] components
;;

let path_of_components root components =
  List.fold_left Filename.concat root components
;;

let parent_components components =
  match List.rev components with
  | [] -> []
  | _file :: parents_rev -> List.rev parents_rev
;;

let ensure_secret_directory_chain ~label root components =
  match ensure_secret_directory ~label root with
  | Error _ as err -> err
  | Ok () ->
    let rec loop current = function
      | [] -> Ok ()
      | component :: rest ->
        let next = Filename.concat current component in
        (match ensure_secret_directory ~label next with
         | Error _ as err -> err
         | Ok () -> loop next rest)
    in
    loop root components
;;

let existing_secret_directory ~label path =
  try
    let st = Unix.lstat path in
    match st.Unix.st_kind with
    | Unix.S_DIR -> Ok true
    | Unix.S_LNK ->
      Error
        (Printf.sprintf
           "keeper secret %s path must not be a symlink: %s"
           label
           path)
    | _ ->
      Error (Printf.sprintf "keeper secret %s path is not a directory: %s" label path)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | Unix.Unix_error (err, fn, arg) -> Error (unix_error_message err fn arg)
;;

let existing_secret_directory_chain ~label root components =
  match existing_secret_directory ~label root with
  | Error _ as err -> err
  | Ok false -> Ok false
  | Ok true ->
    let rec loop current = function
      | [] -> Ok true
      | component :: rest ->
        let next = Filename.concat current component in
        (match existing_secret_directory ~label next with
         | Error _ as err -> err
         | Ok false -> Ok false
         | Ok true -> loop next rest)
    in
    loop root components
;;

let validate_file_entry_target path =
  try
    let st = Unix.lstat path in
    match st.Unix.st_kind with
    | Unix.S_REG -> Ok ()
    | Unix.S_LNK ->
      Error
        (Printf.sprintf "keeper secret file entry must not be a symlink: %s" path)
    | _ ->
      Error
        (Printf.sprintf
           "keeper secret file entry must be a regular file: %s"
           path)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | Unix.Unix_error (err, fn, arg) -> Error (unix_error_message err fn arg)
;;

let set_file_entry ~base_path ~keeper_name ~scope ~container_path ~value =
  match reject_base_keeper_scope_mutation ~keeper_name ~scope with
  | Error _ as err -> err
  | Ok () ->
    if contains_char value '\000'
    then Error "keeper secret file value must not contain NUL"
    else
      match file_rel_components_of_container_path container_path with
      | Error _ as err -> err
      | Ok components ->
        let info = secret_root_info_for_scope ~base_path ~keeper_name scope in
        let files_root = Filename.concat info.root "files" in
        let parent_components = parent_components components in
        (match ensure_secret_directory ~label:"root" info.root with
         | Error _ as err -> err
         | Ok () ->
           (match ensure_secret_directory ~label:"files" files_root with
            | Error _ as err -> err
            | Ok () ->
              (match
                 ensure_secret_directory_chain
                   ~label:"files"
                   files_root
                   parent_components
               with
               | Error _ as err -> err
               | Ok () ->
                 let path = path_of_components files_root components in
                 (match validate_file_entry_target path with
                  | Error _ as err -> err
                  | Ok () ->
                    (match Fs_compat.save_file_atomic path value with
                     | Error _ as err -> err
                     | Ok () ->
                       (try
                          Unix.chmod path 0o600;
                          Ok ()
                        with
                        | Unix.Unix_error (err, fn, arg) ->
                          Error (unix_error_message err fn arg)))))))
;;

let delete_file_entry ~base_path ~keeper_name ~scope ~container_path =
  match reject_base_keeper_scope_mutation ~keeper_name ~scope with
  | Error _ as err -> err
  | Ok () ->
    match file_rel_components_of_container_path container_path with
    | Error _ as err -> err
    | Ok components ->
      let info = secret_root_info_for_scope ~base_path ~keeper_name scope in
    let files_root = Filename.concat info.root "files" in
    let parent_components = parent_components components in
    (match existing_secret_directory ~label:"root" info.root with
     | Error _ as err -> err
     | Ok false -> Ok ()
     | Ok true ->
       (match existing_secret_directory ~label:"files" files_root with
        | Error _ as err -> err
        | Ok false -> Ok ()
        | Ok true ->
          (match
             existing_secret_directory_chain
               ~label:"files"
               files_root
               parent_components
           with
           | Error _ as err -> err
           | Ok false -> Ok ()
           | Ok true ->
             let path = path_of_components files_root components in
             (match validate_file_entry_target path with
              | Error _ as err -> err
              | Ok () ->
                (try
                   if path_exists path then Sys.remove path;
                   Ok ()
                 with
                 | Sys_error msg -> Error msg
                 | Unix.Unix_error (err, fn, arg) ->
                   Error (unix_error_message err fn arg))))))
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
       | Sys_error msg ->
         Log.Keeper.warn "Failed to remove projected secret file during cleanup: %s (Sys_error: %s)" path msg
       | Unix.Unix_error (err, fn, arg) ->
         let msg = unix_error_message err fn arg in
         Log.Keeper.warn "Failed to remove projected secret file during cleanup: %s (Unix_error: %s)" path msg)
    paths
;;

let github_token_env_names = [ "GH_TOKEN"; "GITHUB_TOKEN" ]

let has_github_token entries =
  List.exists
    (fun key ->
       List.exists
         (fun (name, value) -> String.equal name key && not (String.equal value ""))
         entries)
    github_token_env_names
;;

let git_config_global_env_name = "GIT_CONFIG_GLOBAL"

let git_config_helper_content =
  "[credential \"https://github.com\"]\n\thelper = \"!gh auth git-credential\"\n"
;;

let local_git_config_global_path ~base_path ~keeper_name =
  let playground =
    Filename.concat base_path (Playground_paths.bundle_root keeper_name)
  in
  Filename.concat playground ".gitconfig"
;;

let ensure_local_git_config_global ~path =
  try
    ensure_dir (Filename.dirname path);
    match Fs_compat.save_file_atomic path git_config_helper_content with
    | Ok () -> Ok ()
    | Error err -> Error err
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

let github_app_pem_subpath = "github-app/private-key.pem"

let github_app_pem_host_path ~base_path ~keeper_name =
  let root = secret_root ~base_path ~keeper_name in
  Filename.concat (Filename.concat root "files") github_app_pem_subpath
;;

let read_file_result path =
  if not (path_exists path)
  then Error (Printf.sprintf "file does not exist: %s" path)
  else
    try Ok (read_file path) with
    | Sys_error msg -> Error msg
    | Unix.Unix_error (err, fn, arg) -> Error (unix_error_message err fn arg)
;;

(* [github_app_token_overlay] mints (or reuses the cached) GitHub App
   installation token for the keeper. [Ok None] means no GitHub App config is
   present, so the existing static token path remains available. Once either
   GitHub App env key is configured, missing config, unreadable PEM, or mint
   failure returns [Error] so the keeper does not silently fall back to a
   broader static PAT. *)
let github_app_token_overlay ~base_path ~keeper_name ~env_entries () =
  let app_id = List.assoc_opt "MASC_GITHUB_APP_ID" env_entries in
  let installation_id =
    List.assoc_opt "MASC_GITHUB_APP_INSTALLATION_ID" env_entries
  in
  match (app_id, installation_id) with
  | Some app_id, Some installation_id ->
    (match
       github_app_pem_host_path ~base_path ~keeper_name |> read_file_result
     with
     | Error reason ->
       Error
         (Printf.sprintf
            "github_app_private_key_unavailable: %s"
            reason)
     | Ok pem ->
       let now = Time_compat.now () |> int_of_float in
       (match
          Keeper_github_app_installation_token.get
            ~app_id ~installation_id ~pem ~now ()
        with
        | Ok token -> Ok (Some token)
        | Error reason ->
          Log.Keeper.warn
            "GitHub App installation token mint failed for keeper %s: %s"
            keeper_name reason;
          Error
            (Printf.sprintf
               "github_app_installation_token_unavailable: %s"
               reason)))
  | None, None -> Ok None
  | Some _, None -> Error "github_app_config_incomplete: missing MASC_GITHUB_APP_INSTALLATION_ID"
  | None, Some _ -> Error "github_app_config_incomplete: missing MASC_GITHUB_APP_ID"
;;

let without_github_token_env entries =
  List.filter
    (fun (name, _) ->
       not
         (List.exists
            (fun github_token_name -> String.equal name github_token_name)
            github_token_env_names))
    entries
;;

let with_github_app_token_env ~token entries =
  ("GH_TOKEN", token) :: without_github_token_env entries
;;

let env_entries_with_github_app_overlay ~base_path ~keeper_name env_entries =
  match github_app_token_overlay ~base_path ~keeper_name ~env_entries () with
  | Error _ as err -> err
  | Ok (Some token) -> Ok (with_github_app_token_env ~token env_entries)
  | Ok None -> Ok env_entries
;;

let local_env_for_keeper ?host_env ~base_path ~keeper_name () =
  match load_secret_roots ~base_path ~keeper_name with
  | Error _ as err -> err
  | Ok roots ->
    let env_entries = merge_env_entries roots in
    (match env_entries_with_github_app_overlay ~base_path ~keeper_name env_entries with
     | Error _ as err -> err
     | Ok env_entries ->
       let git_config_path = local_git_config_global_path ~base_path ~keeper_name in
    let needs_managed_git_config =
      has_github_token env_entries
      && not (env_entries_have git_config_global_env_name env_entries)
    in
    if needs_managed_git_config
    then (
      match ensure_local_git_config_global ~path:git_config_path with
      | Error _ as err -> err
      | Ok () ->
        let env_entries =
          (git_config_global_env_name, git_config_path) :: env_entries
        in
        let env_entries = local_env_entries_with_defaults env_entries in
        let base = local_base_host_env ?host_env () in
        Ok (Some (overlay_env_entries base env_entries)))
    else
      let env_entries = local_env_entries_with_defaults env_entries in
      let base = local_base_host_env ?host_env () in
       Ok (Some (overlay_env_entries base env_entries)))
;;

let docker_git_config_global_path =
  Filename.concat
    (Keeper_sandbox_runtime_setup.container_masc_dir ~container_root:"")
    "gitconfig"
;;

let docker_git_config_host_path ~base_path ~keeper_name =
  let dir =
    Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path) "tmp")
      "gitconfig"
  in
  Filename.concat dir (Workspace_utils.safe_filename keeper_name ^ ".gitconfig")
;;

let ensure_docker_git_config_global ~base_path ~keeper_name =
  let path = docker_git_config_host_path ~base_path ~keeper_name in
  try
    ensure_dir (Filename.dirname path);
    match Fs_compat.save_file_atomic path git_config_helper_content with
    | Ok () -> Ok path
    | Error err -> Error err
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

let docker_args_for_keeper ~base_path ~keeper_name ~container_name =
  match load_secret_roots ~base_path ~keeper_name with
  | Error _ as err -> err
  | Ok roots ->
    let env_entries = merge_env_entries roots in
    (match env_entries_with_github_app_overlay ~base_path ~keeper_name env_entries with
     | Error _ as err -> err
     | Ok env_entries ->
       let file_entries = merge_file_entries roots in
    let git_config =
      if env_entries_have git_config_global_env_name env_entries
         || not (has_github_token env_entries)
      then Ok None
      else
        match ensure_docker_git_config_global ~base_path ~keeper_name with
        | Error _ as err -> err
        | Ok path -> Ok (Some path)
    in
    (match git_config with
     | Error _ as err -> err
     | Ok git_config ->
       let env_entries =
         match git_config with
         | None -> env_entries
         | Some _ -> (git_config_global_env_name, docker_git_config_global_path) :: env_entries
       in
       (match write_env_file ~base_path ~container_name env_entries with
        | Error _ as err -> err
        | Ok env_file ->
          let env_args =
            match env_file with
            | None -> []
            | Some path -> [ "--env-file"; path ]
          in
          let git_config_mount =
            match git_config with
            | None -> []
            | Some path -> [ path, docker_git_config_global_path ]
          in
          let file_args =
            file_entries @ git_config_mount
            |> List.concat_map (fun (host, container) ->
              [ "-v"; host ^ ":" ^ container ^ ":ro" ])
          in
          let cleanup_paths =
            (match env_file with
             | None -> []
             | Some path -> [ path ])
          in
          let cleanup = fun () -> cleanup_files cleanup_paths in
          Ok { docker_args = env_args @ file_args; cleanup })))
;;
