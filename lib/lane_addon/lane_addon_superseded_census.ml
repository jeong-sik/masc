type report = {
  eligible : int;
  eligible_bytes : int64;
  kept : int;
  kept_bytes : int64;
  observations_bytes : int64;
}

let ( let* ) = Result.bind

let sum bytes items =
  List.fold_left
    (fun total item ->
       let* total = total in
       let* item_bytes = bytes item in
       Ok (Int64.add total item_bytes))
    (Ok 0L) items

let rec tree_bytes path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok 0L
  | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  | { Unix.st_kind = Unix.S_REG; st_size; _ } -> Ok (Int64.of_int st_size)
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    (match Sys.readdir path with
     | exception Sys_error _ -> Error "a directory could not be listed"
     | names -> sum (fun name -> tree_bytes (Filename.concat path name)) (Array.to_list names))
  | { Unix.st_kind = Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK; _ } ->
    Ok 0L

(* The store keeps one instance's action receipts in one directory; the
   directory of any receipt path of that instance is that directory. *)
let action_dir instance_id =
  Filename.dirname (Lane_addon_store.action_path ~instance_id ~request_id:"")

let instance_bytes ~root instance_id =
  sum
    (fun relative -> tree_bytes (Filename.concat root relative))
    [ Lane_addon_store.binding_path instance_id;
      Lane_addon_store.observation_dir instance_id;
      action_dir instance_id ]

let count ~root ~eligible ~kept =
  let* eligible_bytes = sum (instance_bytes ~root) eligible in
  let* kept_bytes = sum (instance_bytes ~root) kept in
  let observations = Filename.dirname (Lane_addon_store.observation_dir "") in
  let* observations_bytes = tree_bytes (Filename.concat root observations) in
  Ok
    { eligible = List.length eligible;
      eligible_bytes;
      kept = List.length kept;
      kept_bytes;
      observations_bytes }
