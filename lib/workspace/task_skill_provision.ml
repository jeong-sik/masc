let ( let* ) = Result.bind

let provision_one ~base_path ~keeper_name skill_name =
  let source_skill_dir =
    Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path) "skills")
      skill_name
  in
  let playground_root =
    Filename.concat base_path (Playground_paths.bundle_root keeper_name)
  in
  let target_skill_dir =
    Filename.concat
      (Filename.concat (Filename.concat playground_root Common.masc_dirname) "skills")
      skill_name
  in
  match Fs_compat.exact_path_kind ~follow:true source_skill_dir with
  | Fs_compat.Exact_kind Unix.S_DIR ->
    Fs_compat.mkdir_p target_skill_dir;
    (match Fs_compat.read_dir source_skill_dir with
     | exception exn ->
       Error (Printf.sprintf "Failed to read skill directory %s: %s" source_skill_dir (Printexc.to_string exn))
     | files ->
       List.fold_left
         (fun acc file ->
            let* () = acc in
            let src_path = Filename.concat source_skill_dir file in
            let dst_path = Filename.concat target_skill_dir file in
            match Fs_compat.exact_path_kind ~follow:true src_path with
            | Fs_compat.Exact_kind Unix.S_REG ->
              (try
                 let contents = Fs_compat.load_file src_path in
                 Fs_compat.save_file dst_path contents;
                 Ok ()
               with exn ->
                 Error (Printf.sprintf "Failed to copy skill file %s: %s" src_path (Printexc.to_string exn)))
            | Fs_compat.Exact_missing | Fs_compat.Exact_unknown
            | Fs_compat.Exact_kind
                ( Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
                | Unix.S_SOCK ) -> Ok ())
         (Ok ())
         files)
  | Fs_compat.Exact_missing ->
    Error (Printf.sprintf "Task skill directory %s does not exist" source_skill_dir)
  | Fs_compat.Exact_unknown
  | Fs_compat.Exact_kind
      ( Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
      | Unix.S_SOCK ) ->
    Error (Printf.sprintf "Task skill path %s is not a regular directory" source_skill_dir)
;;

let provision_skills ~base_path ~keeper_name skills =
  List.fold_left
    (fun acc skill_name ->
       let* () = acc in
       provision_one ~base_path ~keeper_name skill_name)
    (Ok ())
    skills
;;
