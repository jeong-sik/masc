(** See [lsp_reference_index.mli]. *)

type presence =
  | Present
  | Missing of
      { build_command : string
      ; searched : string
      }

(* [Unix.lstat] rather than [Sys.is_directory]: the latter follows symlinks,
   and a build directory that links to an ancestor would walk forever. *)
let is_real_directory path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } -> true
  | _ -> false
  | exception Unix.Unix_error _ -> false
;;

let rec holds_artifact ~suffix dir =
  match Sys.readdir dir with
  | exception Sys_error _ -> false
  | entries ->
    Array.exists
      (fun entry ->
        let path = Filename.concat dir entry in
        if Filename.check_suffix entry suffix
        then true
        else if is_real_directory path
        then holds_artifact ~suffix path
        else false)
      entries
;;

let check ~language ~project_root =
  match Lsp_process_manager.reference_index_of_language language with
  | None -> Present
  | Some { Lsp_process_manager.artifact_suffix; search_root; build_command } ->
    let searched = Filename.concat project_root search_root in
    if is_real_directory searched && holds_artifact ~suffix:artifact_suffix searched
    then Present
    else Missing { build_command; searched }
;;
