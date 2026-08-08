(** File-backed checkpoint persistence using Eio.Path.

    Layout: [<base_dir>/<session_id>.json].
    Atomic writes via {!Fs_atomic_eio.save_atomic}: unique per-writer
    tmp + fsync + rename + dir fsync. *)

type t = { base_dir : Eio.Fs.dir_ty Eio.Path.t }

(** Validate session_id: reject empty, containing '/', containing '\000'. *)
let validate_session_id id =
  if String.length id = 0
  then Error (Error.Io (ValidationFailed { detail = "session_id must not be empty" }))
  else if String.contains id '/'
  then Error (Error.Io (ValidationFailed { detail = "session_id must not contain '/'" }))
  else if String.contains id '\000'
  then
    Error
      (Error.Io (ValidationFailed { detail = "session_id must not contain null byte" }))
  else Ok ()
;;

let io_error_of_exn = Fs_result.io_error_of_exn

let create base_dir =
  try
    Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 base_dir;
    Ok { base_dir }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> io_error_of_exn ~op:"create" ~path:"checkpoint_dir" exn
;;

let file_path store id = Eio.Path.(store.base_dir / (id ^ ".json"))

let save store (cp : Checkpoint.t) =
  match validate_session_id cp.session_id with
  | Error e -> Error e
  | Ok () ->
    let data = Checkpoint.to_string cp in
    Fs_atomic_eio.save_atomic ~dir:store.base_dir ~name:(cp.session_id ^ ".json") data
;;

let load store id =
  match validate_session_id id with
  | Error e -> Error e
  | Ok () ->
    let path = file_path store id in
    (try
       let data = Eio.Path.load path in
       Checkpoint.of_string data
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn -> io_error_of_exn ~op:"load" ~path:id exn)
;;

let list store =
  try
    let entries = Eio.Path.read_dir store.base_dir in
    Ok
      (entries
       |> List.filter (fun name ->
         let len = String.length name in
         (* Exclude any *.tmp sibling — writer-unique tmp names no
              longer end in exactly ".json.tmp"; match the ".tmp"
              suffix directly. *)
         len > 5
         && String.sub name (len - 5) 5 = ".json"
         && not (len > 4 && String.sub name (len - 4) 4 = ".tmp"))
       |> List.map (fun name -> String.sub name 0 (String.length name - 5))
       |> List.sort String.compare)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> io_error_of_exn ~op:"list" ~path:"checkpoint_dir" exn
;;

let delete store id =
  match validate_session_id id with
  | Error e -> Error e
  | Ok () ->
    let path = file_path store id in
    (try
       Eio.Path.unlink path;
       Ok ()
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn -> io_error_of_exn ~op:"delete" ~path:id exn)
;;

let exists store id =
  match validate_session_id id with
  | Error _ -> false
  | Ok () ->
    let path = file_path store id in
    Eio.Path.is_file path
;;

let latest store =
  match list store with
  | Error e -> Error e
  | Ok ids ->
    if ids = []
    then
      Error
        (Error.Io
           (FileOpFailed { op = "latest"; path = ""; detail = "No checkpoints found" }))
    else (
      let best =
        List.fold_left
          (fun acc id ->
             match load store id with
             | Error _ -> acc
             | Ok cp ->
               (match acc with
                | None -> Some cp
                | Some prev ->
                  if cp.created_at > prev.created_at then Some cp else Some prev))
          None
          ids
      in
      match best with
      | Some cp -> Ok cp
      | None ->
        Error
          (Error.Serialization (JsonParseError { detail = "All checkpoints corrupted" })))
;;
