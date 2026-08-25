let skill_dir ~base_path name =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path) "skills")
    name
;;

let skill_path ~base_path name =
  Filename.concat (skill_dir ~base_path name) "SKILL.md"
;;

let validate_name name =
  if
    String.equal name (String.trim name)
    && Safe_identifier.is_portable_name name
    && not (String.equal name ".")
    && not (String.equal name "..")
  then Ok ()
  else
    Error
      (Printf.sprintf
         "task skill %S must be one non-empty portable path segment"
         name)
;;

let validate_definition ~name contents =
  match Agent_core.Skill_document.decode ~directory_name:name contents with
  | Loaded _ -> Ok ()
  | Unloadable diagnostics ->
    Error
      (Printf.sprintf
         "task skill %S is invalid: %s"
         name
         (String.concat
            "; "
            (List.map Agent_core.Skill_document.diagnostic_to_string diagnostics)))
;;

let validate_one ~base_path name =
  let ( let* ) = Result.bind in
  let* () = validate_name name in
  let directory = skill_dir ~base_path name in
  let path = skill_path ~base_path name in
  match Fs_compat.exact_path_kind ~follow:false directory with
  | Fs_compat.Exact_kind Unix.S_DIR ->
    (match Fs_compat.exact_path_kind ~follow:false path with
     | Fs_compat.Exact_kind Unix.S_REG ->
       (match Safe_ops.read_file_safe path with
        | Error detail ->
          Error (Printf.sprintf "task skill %S is unreadable: %s" name detail)
        | Ok contents -> validate_definition ~name contents)
     | Fs_compat.Exact_missing ->
       Error (Printf.sprintf "task skill %S does not exist at %s" name path)
     | Fs_compat.Exact_kind Unix.S_LNK ->
       Error
         (Printf.sprintf
            "task skill %S SKILL.md must not be a symlink: %s"
            name
            path)
     | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
       Error
         (Printf.sprintf "task skill %S is not a regular SKILL.md: %s" name path))
  | Fs_compat.Exact_kind Unix.S_LNK ->
    Error
      (Printf.sprintf
         "task skill %S directory must not be a symlink: %s"
         name
         directory)
  | Fs_compat.Exact_missing ->
    Error (Printf.sprintf "task skill %S does not exist at %s" name path)
  | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
    Error
      (Printf.sprintf
         "task skill %S directory is not a regular directory: %s"
         name
         directory)
;;

let validate_all ~base_path names =
  List.fold_left
    (fun result name -> Result.bind result (fun () -> validate_one ~base_path name))
    (Ok ())
    names
;;
