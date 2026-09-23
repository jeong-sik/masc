let ( let* ) = Result.bind

module Store = Keeper_chat_operation_store
module String_set = Set.Make (String)

type report =
  { live_references : int
  ; removed : int
  ; removed_bytes : int
  ; failures : string list
  }

type error =
  | Store_unreadable of { path : string; detail : string }
  | Keeper_shares_store_directory of { keeper_name : string }

let error_to_string = function
  | Store_unreadable { path; detail } ->
    Printf.sprintf "keeper operation store %s is unreadable: %s" path detail
  | Keeper_shares_store_directory { keeper_name } ->
    Printf.sprintf
      "keeper %s has the directory of the keepers/ store of the same name" keeper_name

let retained_suffix = ".json"

let sorted_entries dir =
  match Sys.readdir dir with
  | entries ->
    Array.sort String.compare entries;
    Ok (Array.to_list entries)
  | exception Sys_error detail -> Error detail

(* [~follow:true] resolves symlinks the way the runtime does when it opens a
   keeper's store; the session tree is walked without following them, so the
   sweep never removes through a link. *)
let kind ?(follow = false) path =
  match (if follow then Unix.stat else Unix.lstat) path with
  | { Unix.st_kind; st_size; _ } -> Ok (Some (st_kind, st_size))
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | exception Unix.Unix_error (code, _, _) -> Error (path ^ ": " ^ Unix.error_message code)

let is_directory ?follow path =
  match kind ?follow path with
  | Ok (Some (Unix.S_DIR, _)) -> Ok true
  | Ok (Some ((Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK), _))
  | Ok None -> Ok false
  | Error _ as error -> error

let live_references_of_store path =
  match Store.inspect_outstanding ~path with
  | Error error ->
    Error (Store_unreadable { path; detail = Store.error_to_string error })
  | Ok Store.Missing_store -> Ok []
  | Ok (Store.Stored_operations { semantic_executions; chat_operations = _ }) ->
    Ok
      (List.concat_map
         (fun execution ->
            Keeper_semantic_execution.checkpoint_references execution
            |> List.map (fun (reference : Keeper_checkpoint_ref.t) -> reference.sha256))
         semantic_executions)

let live_references ~runtime_root =
  let keepers_dir = Filename.concat runtime_root Common.keepers_runtime_dirname in
  let unreadable detail = Store_unreadable { path = keepers_dir; detail } in
  let* present = is_directory ~follow:true keepers_dir |> Result.map_error unreadable in
  if not present
  then Ok String_set.empty
  else
    let* keeper_names = sorted_entries keepers_dir |> Result.map_error unreadable in
    List.fold_left
      (fun acc keeper_name ->
         let* live = acc in
         let* keeper_dir =
           is_directory ~follow:true (Filename.concat keepers_dir keeper_name)
           |> Result.map_error unreadable
         in
         let root_store = Common.is_keepers_root_store_dirname keeper_name in
         let has_metadata () =
           Sys.file_exists
             (Filename.concat keepers_dir
                (Keeper_runtime_root_entry.keeper_basename ~keeper_name
                   Keeper_runtime_root_entry.Metadata))
         in
         if not keeper_dir
         then Ok live
         else if root_store && has_metadata ()
         then Error (Keeper_shares_store_directory { keeper_name })
         else if root_store
         then Ok live
         else
           let path =
             Store.path_for_keeper ~keepers_runtime_dir:keepers_dir ~keeper_name
           in
           let* shas = live_references_of_store path in
           Ok (List.fold_left (fun set sha -> String_set.add sha set) live shas))
      (Ok String_set.empty)
      keeper_names

let failed report detail = { report with failures = detail :: report.failures }

let remove_unreferenced ~live dir report =
  match sorted_entries dir with
  | Error detail -> failed report detail
  | Ok names ->
    List.fold_left
      (fun report name ->
         match Filename.chop_suffix_opt ~suffix:retained_suffix name with
         | None -> report
         | Some sha when String_set.mem sha live -> report
         | Some _ ->
           let path = Filename.concat dir name in
           (match kind path with
            | Error detail -> failed report detail
            | Ok (Some (Unix.S_REG, size)) ->
              (match Sys.remove path with
               | () ->
                 { report with
                   removed = report.removed + 1
                 ; removed_bytes = report.removed_bytes + size
                 }
               | exception Sys_error detail -> failed report detail)
            | Ok (Some ((Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK), _))
            | Ok None -> report))
      report
      names

(* Session directories nest under scope components, so every directory under
   the session root is visited; symlinks are not followed. *)
let rec sweep_tree ~live dir report =
  match sorted_entries dir with
  | Error detail -> failed report detail
  | Ok names ->
    List.fold_left
      (fun report name ->
         let path = Filename.concat dir name in
         match is_directory path with
         | Error detail -> failed report detail
         | Ok false -> report
         | Ok true when String.equal name Keeper_checkpoint_store.retained_dirname ->
           remove_unreferenced ~live path report
         | Ok true -> sweep_tree ~live path report)
      report
      names

let run ~runtime_root =
  let* live = live_references ~runtime_root in
  let session_root = Keeper_fs.session_store_path_for_runtime_root runtime_root in
  let empty =
    { live_references = String_set.cardinal live; removed = 0; removed_bytes = 0; failures = [] }
  in
  let report =
    match is_directory session_root with
    | Error detail -> failed empty detail
    | Ok false -> empty
    | Ok true -> sweep_tree ~live session_root empty
  in
  Ok { report with failures = List.rev report.failures }
