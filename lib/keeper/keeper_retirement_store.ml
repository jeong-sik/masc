let schema_version = 1

type entry =
  { trace_id : Keeper_id.Trace_id.t
  ; operation_id : Keeper_shutdown_types.Operation_id.t
  }

let retirements_dir (config : Workspace.config) =
  Filename.concat (Workspace.keepers_runtime_dir config) ".retirements"
;;

(* Same reversible prefix scheme as the shutdown store's owner directories:
   it keeps the valid names [.] and [..] from becoming directory traversal. *)
let file_name_of_keeper_name keeper_name = "_" ^ keeper_name ^ ".json"

let store_path ~config ~keeper_name =
  Filename.concat (retirements_dir config) (file_name_of_keeper_name keeper_name)
;;

let ( let* ) = Result.bind

let entry_to_json entry =
  `Assoc
    [ "trace_id", `String (Keeper_id.Trace_id.to_string entry.trace_id)
    ; ( "operation_id"
      , `String (Keeper_shutdown_types.Operation_id.to_string entry.operation_id) )
    ]
;;

let entry_of_json = function
  | `Assoc fields ->
    let field name =
      match List.assoc_opt name fields with
      | Some (`String value) -> Ok value
      | Some _ | None ->
        Error
          (Printf.sprintf "retirement entry field %S missing or not a string" name)
    in
    let* trace = field "trace_id" in
    let* operation = field "operation_id" in
    let* trace_id = Keeper_id.Trace_id.of_string trace in
    let* operation_id = Keeper_shutdown_types.Operation_id.of_string operation in
    Ok { trace_id; operation_id }
  | _ -> Error "retirement entry is not an object"
;;

let to_json entries =
  `Assoc
    [ "schema_version", `Int schema_version
    ; "retirements", `List (List.map entry_to_json entries)
    ]
;;

let of_json = function
  | `Assoc fields ->
    (match
       List.assoc_opt "schema_version" fields, List.assoc_opt "retirements" fields
     with
     | Some (`Int version), Some (`List entries) when Int.equal version schema_version
       ->
       List.fold_left
         (fun acc json ->
           let* entries = acc in
           let* entry = entry_of_json json in
           Ok (entry :: entries))
         (Ok [])
         entries
       |> Result.map List.rev
     | Some (`Int version), _ ->
       Error (Printf.sprintf "unsupported retirement schema_version %d" version)
     | _, _ -> Error "retirement document missing schema_version or retirements")
  | _ -> Error "retirement document is not an object"
;;

type lock_access =
  | Read
  | Write

let with_store_lock ~access ~config ~keeper_name f =
  let key = store_path ~config ~keeper_name in
  let lock = Keeper_fs.acquire_path_lock key in
  Fun.protect
    ~finally:(fun () -> Keeper_fs.release_path_lock key lock)
    (fun () ->
      match access with
      | Write -> Eio.Mutex.use_rw ~protect:true (Keeper_fs.path_lock_mutex lock) f
      | Read -> Eio.Mutex.use_ro (Keeper_fs.path_lock_mutex lock) f)
;;

let load_unlocked path =
  if not (Fs_compat.file_exists path)
  then Ok []
  else (
    match Fs_compat.load_file path with
    | exception exn ->
      Error (Printf.sprintf "%s: %s" path (Printexc.to_string exn))
    | content ->
      (match Yojson.Safe.from_string content with
       | exception Yojson.Json_error detail ->
         Error (Printf.sprintf "%s: %s" path detail)
       | json -> of_json json))
;;

let entry_equal left right =
  Keeper_id.Trace_id.equal left.trace_id right.trace_id
  && Keeper_shutdown_types.Operation_id.equal left.operation_id right.operation_id
;;

let record ~config ~keeper_name entry =
  let path = store_path ~config ~keeper_name in
  with_store_lock ~access:Write ~config ~keeper_name (fun () ->
    let* existing = load_unlocked path in
    if List.exists (entry_equal entry) existing
    then Ok ()
    else (
      Fs_compat.mkdir_p (retirements_dir config);
      Keeper_fs.save_json_atomic path (to_json (existing @ [ entry ]))))
;;

let list_for_keeper ~config ~keeper_name =
  let path = store_path ~config ~keeper_name in
  with_store_lock ~access:Read ~config ~keeper_name (fun () -> load_unlocked path)
;;
