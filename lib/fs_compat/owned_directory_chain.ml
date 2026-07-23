(* See [owned_directory_chain.mli] for the contract. *)

type rejection =
  | Owned_path_outside_root of
      { ownership_root : string
      ; path : string
      }
  | Owned_path_non_directory of
      { path : string
      ; kind : Unix.file_kind
      }

type observation =
  | Owned_directory_missing
  | Owned_directory of Unix.stats

let file_kind_to_string = function
  | Unix.S_REG -> "regular_file"
  | Unix.S_DIR -> "directory"
  | Unix.S_CHR -> "character_device"
  | Unix.S_BLK -> "block_device"
  | Unix.S_LNK -> "symbolic_link"
  | Unix.S_FIFO -> "fifo"
  | Unix.S_SOCK -> "socket"
;;

let rejection_to_string = function
  | Owned_path_outside_root { ownership_root; path } ->
    Printf.sprintf "path %s is outside ownership root %s" path ownership_root
  | Owned_path_non_directory { path; kind } ->
    Printf.sprintf
      "owned directory component %s has kind %s"
      path
      (file_kind_to_string kind)
;;

let relative_components ~ownership_root path =
  if Filename.is_relative ownership_root || Filename.is_relative path
  then Error (Owned_path_outside_root { ownership_root; path })
  else
    let rec ascend components current =
      if String.equal current ownership_root
      then Ok components
      else
        let parent = Filename.dirname current in
        let component = Filename.basename current in
        if
          String.equal parent current
          || String.equal component Filename.current_dir_name
          || String.equal component Filename.parent_dir_name
        then Error (Owned_path_outside_root { ownership_root; path })
        else ascend (component :: components) parent
    in
    ascend [] path
;;

let paths ~ownership_root path =
  relative_components ~ownership_root path
  |> Result.map (fun components ->
    let _, paths =
      List.fold_left
        (fun (parent, paths) component ->
           let child = Filename.concat parent component in
           child, child :: paths)
        (ownership_root, [])
        components
    in
    List.rev paths)
;;

let lstat_directory path =
  match Unix.lstat path with
  | stat when stat.Unix.st_kind = Unix.S_DIR -> Ok (Owned_directory stat)
  | stat -> Error (Owned_path_non_directory { path; kind = stat.Unix.st_kind })
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Owned_directory_missing
;;

let inspect ~ownership_root path =
  match paths ~ownership_root path with
  | Error _ as rejection -> rejection
  | Ok descendants ->
    (match lstat_directory ownership_root with
     | Error _ as rejection -> rejection
     | Ok Owned_directory_missing -> Ok Owned_directory_missing
     | Ok (Owned_directory root_stat) ->
       let rec descend current_stat = function
         | [] -> Ok (Owned_directory current_stat)
         | child :: rest ->
           (match lstat_directory child with
            | Error _ as rejection -> rejection
            | Ok Owned_directory_missing -> Ok Owned_directory_missing
            | Ok (Owned_directory stat) -> descend stat rest)
       in
       descend root_stat descendants)
;;
