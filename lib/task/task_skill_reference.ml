let skill_path ~base_path name =
  Filename.concat
    (Filename.concat
       (Filename.concat (Common.masc_dir_from_base_path ~base_path) "skills")
       name)
    "SKILL.md"
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
  if not (Frontmatter.has_frontmatter contents)
  then Error (Printf.sprintf "task skill %S has no frontmatter" name)
  else
    let frontmatter = Frontmatter.parse contents in
    let declared_name = String.trim (Frontmatter.field frontmatter "name") in
    let description = String.trim (Frontmatter.field frontmatter "description") in
    if String.equal declared_name ""
    then Error (Printf.sprintf "task skill %S has no frontmatter name" name)
    else if not (String.equal declared_name name)
    then
      Error
        (Printf.sprintf
           "task skill name %S does not match directory %S"
           declared_name
           name)
    else if String.equal description ""
    then Error (Printf.sprintf "task skill %S has no description" name)
    else Ok ()
;;

let validate_one ~base_path name =
  let ( let* ) = Result.bind in
  let* () = validate_name name in
  let path = skill_path ~base_path name in
  match Fs_compat.exact_path_kind path with
  | Fs_compat.Exact_kind Unix.S_REG ->
    (match Safe_ops.read_file_safe path with
     | Error detail ->
       Error (Printf.sprintf "task skill %S is unreadable: %s" name detail)
     | Ok contents -> validate_definition ~name contents)
  | Fs_compat.Exact_missing ->
    Error (Printf.sprintf "task skill %S does not exist at %s" name path)
  | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
    Error (Printf.sprintf "task skill %S is not a regular SKILL.md: %s" name path)
;;

let validate_all ~base_path names =
  List.fold_left
    (fun result name -> Result.bind result (fun () -> validate_one ~base_path name))
    (Ok ())
    names
;;
