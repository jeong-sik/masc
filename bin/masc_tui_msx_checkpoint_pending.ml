type binding = { operation_id : Keeper_operation_id.t; restore : bool; slot : string;
  base_path : string; masc_root : string }
let ( let* ) = Result.bind
let directory ~masc_root = Filename.concat (Filename.concat masc_root "tui") "checkpoint-pending"
let name binding = Keeper_operation_id.to_string binding.operation_id ^ ".json"
let fsync_directory path =
  let fd = Unix.openfile path [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
let protect f =
  try f () with
  | Sys_error message | Yojson.Json_error message -> Error message
  | Unix.Unix_error (error, operation, path) ->
      Error (operation ^ " " ^ path ^ ": " ^ Unix.error_message error)
let ensure_directory path =
  try Unix.mkdir path 0o700; fsync_directory (Filename.dirname path)
  with Unix.Unix_error (Unix.EEXIST, _, _) ->
    if not (Sys.is_directory path) then raise (Sys_error "checkpoint intent path is not a directory")
let json binding = `Assoc ["version", `Int 1;
  "operation_id", `String (Keeper_operation_id.to_string binding.operation_id);
  "restore", `Bool binding.restore; "slot", `String binding.slot;
  "base_path", `String binding.base_path; "masc_root", `String binding.masc_root]
let decode = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) =
      ["base_path"; "masc_root"; "operation_id"; "restore"; "slot"; "version"] ->
      (match List.assoc "version" fields, List.assoc "operation_id" fields,
             List.assoc "restore" fields, List.assoc "slot" fields,
             List.assoc "base_path" fields, List.assoc "masc_root" fields with
       | `Int 1, `String raw, `Bool restore, `String slot, `String base_path, `String masc_root
         when not (Filename.is_relative base_path) && not (Filename.is_relative masc_root) ->
           let* operation_id = Keeper_operation_id.of_string raw in
           let* _ = Machine_checkpoint.slot_of_string slot in
           Ok {operation_id; restore; slot; base_path; masc_root}
       | _ -> Error "invalid checkpoint intent fields")
  | _ -> Error "invalid checkpoint intent record"
let load ~masc_root = protect (fun () ->
  let dir = directory ~masc_root in
  match Unix.stat dir with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
  | _ ->
      Array.fold_left (fun result file ->
        let* held = result in
        if String.starts_with ~prefix:".pending-" file && Filename.check_suffix file ".tmp" then Ok held
        else
          let* binding = decode (Yojson.Safe.from_file (Filename.concat dir file)) in
          if binding.masc_root <> masc_root then Error "checkpoint intent workspace root differs"
          else if file <> name binding then Error "checkpoint intent filename differs from binding"
          else Ok (binding :: held)) (Ok []) (Sys.readdir dir))
let with_workspace_lock ~masc_root f =
  let path = Filename.concat (Filename.concat masc_root "tui") "checkpoint-pending.lock" in
  match File_lock_eio.with_durable_lock ~lock_path:path f with
  | Ok result -> result
  | Error error -> Error (File_lock_eio.durable_lock_error_to_string error)
let remember_with ~sync_directory ~masc_root binding = protect (fun () ->
  let* () = if binding.masc_root = masc_root && not (Filename.is_relative binding.base_path)
    && not (Filename.is_relative masc_root) then Ok () else Error "checkpoint intent workspace differs" in
  let* _ = Machine_checkpoint.slot_of_string binding.slot in
  let parent = Filename.concat masc_root "tui" in
  ensure_directory parent;
  with_workspace_lock ~masc_root (fun () ->
    let dir = directory ~masc_root in
    ensure_directory dir;
    let* pending = load ~masc_root in
    match List.find_opt (fun held -> held.operation_id = binding.operation_id) pending with
    | Some existing when existing = binding -> Ok ()
    | Some _ -> Error "checkpoint intent binding conflict"
    | None when pending <> [] -> Error "another checkpoint intent is unresolved"
    | None ->
        let path = Filename.concat dir (name binding) in
        let tmp, channel = Filename.open_temp_file ~temp_dir:dir ".pending-" ".tmp" in
        Fun.protect ~finally:(fun () ->
          close_out_noerr channel;
          try Unix.unlink tmp with Unix.Unix_error (Unix.ENOENT, _, _) -> ()) (fun () ->
            Yojson.Safe.to_channel channel (json binding);
            flush channel;
            Unix.fsync (Unix.descr_of_out_channel channel);
            close_out channel;
            Unix.rename tmp path;
            (* The caller dispatches nothing when this returns an error. An
               intent whose directory entry could not be made durable is
               withdrawn, so the next admission does not wait on a request
               that was never sent. The removal is synced too, or a crash could
               bring the withdrawn intent back. That sync is best effort: a
               directory that just refused one fsync may refuse the next, and
               the caller must still see the first error. *)
            (try sync_directory dir with Unix.Unix_error _ as unsynced ->
               (try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
               (try sync_directory dir with Unix.Unix_error _ -> ());
               raise unsynced);
            Ok ())))
let remember ~masc_root binding = remember_with ~sync_directory:fsync_directory ~masc_root binding
let forget ~masc_root binding = protect (fun () ->
  let* () = if binding.masc_root = masc_root then Ok () else Error "checkpoint intent workspace differs" in
  ensure_directory (Filename.concat masc_root "tui");
  with_workspace_lock ~masc_root (fun () ->
    let dir = directory ~masc_root in
    let path = Filename.concat dir (name binding) in
    let* () =
      match Unix.stat path with
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
      | _ ->
          let* existing = decode (Yojson.Safe.from_file path) in
          if existing <> binding then Error "checkpoint intent binding conflict"
          else (Unix.unlink path; Ok ()) in
    fsync_directory dir;
    Ok ()))
module For_testing = struct
  let remember_with = remember_with
end
