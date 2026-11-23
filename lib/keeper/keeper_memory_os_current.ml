(** Read-only view and boot quarantine of a Keeper's ordinary current Memory OS
    snapshot ([<keeper>.memory-current.json]). *)

include Keeper_memory_os_current_types
include Keeper_memory_os_current_layout

open Result.Syntax
module Snapshot_codec = Keeper_memory_os_snapshot_codec

let sha256 content = Agent_core_sha256.(digest_string content |> to_hex)

let source_kind_to_string = Snapshot_codec.source_kind_to_string
let to_json = Snapshot_codec.to_json
let snapshot_sha256 snapshot = sha256 (Snapshot_codec.snapshot_bytes snapshot)

let parse path content =
  try
    Result.map_error
      (fun rejection ->
         Printf.sprintf
           "%s: current Memory OS snapshot rejected: %s"
           path
           (Snapshot_codec.snapshot_rejection_to_string rejection))
      (Snapshot_codec.of_json (Yojson.Safe.from_string content))
  with
  | Yojson.Json_error message ->
    Error (Printf.sprintf "%s: invalid JSON: %s" path message)
;;

type file_stamp =
  (Unix.file_kind * int * int * int * float * float) option

let stat_identity_result path : (file_stamp, string) result =
  match Unix.stat path with
  | st ->
    Ok
      (Some
         ( st.Unix.st_kind
         , st.Unix.st_dev
         , st.Unix.st_ino
         , st.Unix.st_size
         , st.Unix.st_mtime
         , st.Unix.st_ctime ))
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | exception Unix.Unix_error (code, fn, arg) ->
    Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))
;;

let yield_for_concurrent_writer () =
  match Eio_guard.execution_context () with
  | Eio_guard.Eio_fiber -> Eio.Fiber.yield ()
  | Eio_guard.Non_eio -> Domain.cpu_relax ()
;;

type read_classified =
  | No_snapshot
  | Readable of t
  | Undecodable of { rejection : string }
  | Io_unreadable of { detail : string }

let read_classified ~keepers_dir ~keeper_id =
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  let classify_bytes = function
    | None -> No_snapshot
    | Some content ->
      (match parse snapshot_path content with
       | Ok snapshot -> Readable snapshot
       | Error rejection -> Undecodable { rejection })
  in
  let max_optimistic_attempts = 4 in
  let rec optimistic attempt =
    let observed =
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        try
          match stat_identity_result snapshot_path with
          | Error detail -> `Done (Io_unreadable { detail })
          | Ok snap_before ->
            let bytes = Fs_compat.load_file_opt snapshot_path in
            (match stat_identity_result snapshot_path with
             | Error detail -> `Done (Io_unreadable { detail })
             | Ok snap_after ->
               if snap_before = snap_after
               then `Done (classify_bytes bytes)
               else `Changed)
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | Sys_error message ->
          `Done
            (Io_unreadable
               { detail =
                   Printf.sprintf
                     "current Memory OS read failed path=%s: %s"
                     snapshot_path
                     message
               }))
    in
    match observed with
    | `Done result -> result
    | `Changed when attempt < max_optimistic_attempts ->
      yield_for_concurrent_writer ();
      optimistic (attempt + 1)
    | `Changed -> locked_fallback ()
  and locked_fallback () =
    let copied =
      try
        File_lock_eio.with_lock snapshot_path (fun () ->
          `Bytes (Fs_compat.load_file_opt snapshot_path))
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | Sys_error message ->
        `Error
          (Printf.sprintf
             "current Memory OS read failed path=%s: %s"
             snapshot_path
             message)
      | Unix.Unix_error (code, fn, arg) ->
        `Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))
    in
    match copied with
    | `Bytes bytes ->
      Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
        classify_bytes bytes)
    | `Error detail -> Io_unreadable { detail }
  in
  optimistic 0
;;

let read_with_content ~keepers_dir ~keeper_id =
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  let decode_bytes = function
    | None -> Ok None
    | Some content ->
      let+ snapshot = parse snapshot_path content in
      Some (snapshot, content)
  in
  let max_optimistic_attempts = 4 in
  let rec optimistic attempt =
    let observed =
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        let* snap_before = stat_identity_result snapshot_path in
        let bytes = Fs_compat.load_file_opt snapshot_path in
        let* snap_after = stat_identity_result snapshot_path in
        if snap_before = snap_after
        then
          let+ decoded = decode_bytes bytes in
          `Read decoded
        else Ok `Changed)
    in
    match observed with
    | Ok (`Read decoded) -> Ok decoded
    | Ok `Changed when attempt < max_optimistic_attempts ->
      yield_for_concurrent_writer ();
      optimistic (attempt + 1)
    | Ok `Changed -> locked_fallback ()
    | Error _ as err -> err
  and locked_fallback () =
    let bytes =
      File_lock_eio.with_lock snapshot_path (fun () ->
        Fs_compat.load_file_opt snapshot_path)
    in
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
      decode_bytes bytes)
  in
  try optimistic 0 with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error message ->
    Error
      (Printf.sprintf
         "current Memory OS read failed path=%s: %s"
         snapshot_path
         message)
;;

let read_for_keepers_dir ~keepers_dir ~keeper_id =
  read_with_content ~keepers_dir ~keeper_id
  |> Result.map (Option.map fst)
;;

let read_with_snapshot_sha256 ~keepers_dir ~keeper_id =
  read_with_content ~keepers_dir ~keeper_id
  |> Result.map
       (Option.map (fun (snapshot, content) -> snapshot, sha256 content))
;;

let keeper_id_of_filename filename = Filename.chop_suffix_opt ~suffix filename

let list_keeper_ids_for_keepers_dir ~keepers_dir =
  if not (Fs_compat.is_directory keepers_dir)
  then []
  else
    Sys.readdir keepers_dir
    |> Array.to_list
    |> List.filter_map keeper_id_of_filename
    |> List.sort String.compare
;;

let rec missing_directory_or_broken_ancestor path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    let parent = Filename.dirname path in
    if String.equal path parent
    then Error (path ^ ": directory ancestry is absent")
    else missing_directory_or_broken_ancestor parent
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception ((Unix.Unix_error _ | Sys_error _) as exn) ->
    Error (path ^ ": " ^ Printexc.to_string exn)
  | _ ->
    (match Unix.stat path with
     | stat when stat.Unix.st_kind = Unix.S_DIR -> Ok ()
     | _ -> Error (path ^ ": not a directory")
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception ((Unix.Unix_error _ | Sys_error _) as exn) ->
       Error (path ^ ": " ^ Printexc.to_string exn))
;;

let list_keeper_ids_with_suffix ~keepers_dir ~suffix =
  try
    let stat = Unix.stat keepers_dir in
    if stat.Unix.st_kind <> Unix.S_DIR
    then Error (keepers_dir ^ ": not a directory")
    else
      Sys.readdir keepers_dir
      |> Array.to_list
      |> List.filter_map (Filename.chop_suffix_opt ~suffix)
      |> List.sort_uniq String.compare
      |> fun ids -> Ok ids
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
    (match Unix.lstat keepers_dir with
     | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
       let+ () = missing_directory_or_broken_ancestor (Filename.dirname keepers_dir) in
       []
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception ((Unix.Unix_error _ | Sys_error _) as exn) ->
       Error (keepers_dir ^ ": " ^ Printexc.to_string exn)
     | _ -> Error (keepers_dir ^ ": directory target is absent"))
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Unix.Unix_error _ | Sys_error _) as exn ->
    Error (keepers_dir ^ ": " ^ Printexc.to_string exn)
;;

let rejected_marker = ".rejected-"

let is_digits text =
  text <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) text
;;

let rejected_base name =
  let marker = String.length rejected_marker in
  let rec find from =
    if from + marker > String.length name
    then None
    else if String.sub name from marker = rejected_marker
    then (
      let rest =
        String.sub name (from + marker) (String.length name - from - marker)
      in
      let stamped =
        match String.index_opt rest '-' with
        | None -> is_digits rest
        | Some dash ->
          is_digits (String.sub rest 0 dash)
          && is_digits
               (String.sub rest (dash + 1) (String.length rest - dash - 1))
      in
      if stamped && from > 0
      then Some (String.sub name 0 from)
      else find (from + 1))
    else find (from + 1)
  in
  find 0
;;

let unused_rejected_path ~snapshot_path ~now =
  let base = Printf.sprintf "%s%s%.0f" snapshot_path rejected_marker now in
  if not (Fs_compat.file_exists base)
  then base
  else (
    let rec next attempt =
      let candidate = Printf.sprintf "%s-%d" base attempt in
      if Fs_compat.file_exists candidate then next (attempt + 1) else candidate
    in
    next 2)
;;

(* Open without blocking on special files and inspect the opened descriptor,
   not a path that may be replaced between a stat and an open. *)
let preflight_file_unix path =
  let rec inspect_parent parent =
    match Unix.lstat parent with
    | stat ->
      (match stat.Unix.st_kind with
       | Unix.S_DIR -> Ok None
       | Unix.S_LNK ->
         (match Unix.stat parent with
          | target when target.Unix.st_kind = Unix.S_DIR -> Ok None
          | _ -> Error (parent ^ ": not a directory")
          | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
          | exception ((Unix.Unix_error _ | Sys_error _) as exn) ->
            Error (parent ^ ": " ^ Printexc.to_string exn))
       | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
         Error (parent ^ ": not a directory"))
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception ((Unix.Unix_error _ | Sys_error _) as exn) ->
      Error (parent ^ ": " ^ Printexc.to_string exn)
  in
  let rec open_or_inspect attempts_left =
    try
      let fd =
        Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0
      in
      let channel = Unix.in_channel_of_descr fd in
      Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
        if (Unix.fstat fd).Unix.st_kind <> Unix.S_REG
        then Error (path ^ ": not a regular file")
        else Ok (Some (In_channel.input_all channel)))
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) ->
      (match Unix.lstat path with
       | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
         inspect_parent (Filename.dirname path)
       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
       | exception ((Unix.Unix_error _ | Sys_error _) as exn) ->
         Error (path ^ ": " ^ Printexc.to_string exn)
       | { Unix.st_kind = Unix.S_REG; _ } ->
         if attempts_left > 0
         then open_or_inspect (attempts_left - 1)
         else inspect_parent (Filename.dirname path)
       | { Unix.st_kind = Unix.S_LNK; _ } -> Error (path ^ ": file target is absent")
       | { Unix.st_kind =
             Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK
         ; _
         } ->
         Error (path ^ ": not a regular file"))
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | (Unix.Unix_error _ | Sys_error _) as exn ->
      Error (path ^ ": " ^ Printexc.to_string exn)
  in
  open_or_inspect 8
;;

let preflight_file path =
  let result =
    Systhread_host.run ~label:"memory-current-observe-file" (fun () ->
      preflight_file_unix path)
  in
  (match Eio_guard.execution_context () with
   | Eio_guard.Eio_fiber -> Eio.Fiber.check ()
   | Eio_guard.Non_eio -> ());
  result
;;

let quarantine_regular_path path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_REG -> Ok ()
    | Unix.S_LNK -> Error (path ^ ": snapshot symlink requires manual reconciliation")
    | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
      Error (path ^ ": snapshot is not a regular file")
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Unix.Unix_error _ | Sys_error _) as exn ->
    Error (path ^ ": " ^ Printexc.to_string exn)
;;

type boot_observation =
  | Boot_absent
  | Boot_readable
  | Boot_undecodable of
      { rejection : string
      ; snapshot_sha256 : string
      }
  | Boot_unreadable of { detail : string }

let inspect_for_boot ~keepers_dir ~keeper_id =
  let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  let observed =
    let* content = preflight_file path in
    match content with
    | None -> Ok Boot_absent
    | Some content ->
      (match parse path content with
       | Ok _ -> Ok Boot_readable
       | Error rejection ->
         let+ () = quarantine_regular_path path in
         Boot_undecodable { rejection; snapshot_sha256 = sha256 content })
  in
  match observed with
  | Ok observation -> observation
  | Error detail -> Boot_unreadable { detail }
;;

let move_aside_for_keepers_dir
      ?clock
      ~keepers_dir
      ~keeper_id
      ~now
      ~rejection
      ~expected_snapshot_sha256
      ()
  =
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  File_lock_eio.with_lock ?clock snapshot_path (fun () ->
    let* () = quarantine_regular_path snapshot_path in
    let* content = preflight_file snapshot_path in
    let* content =
      Option.to_result ~none:"snapshot disappeared before quarantine" content
    in
    let* () =
      if String.equal (sha256 content) expected_snapshot_sha256
      then Ok ()
      else Error "snapshot changed before quarantine"
    in
    let* () =
      match parse snapshot_path content with
      | Ok _ -> Error "snapshot is readable; quarantine refused"
      | Error actual when String.equal actual rejection -> Ok ()
      | Error _ -> Error "snapshot decoder rejection changed before quarantine"
    in
    let* () = quarantine_regular_path snapshot_path in
    let rejected_path = unused_rejected_path ~snapshot_path ~now in
    match Fs_compat.rename_noreplace snapshot_path rejected_path with
    | () -> Ok rejected_path
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn ->
      Error
        (Printf.sprintf
           "current Memory OS file could not be moved aside path=%s rejected_path=%s: %s (rejected: %s)"
           snapshot_path
           rejected_path
           (Printexc.to_string exn)
           rejection))
;;

module For_testing = struct
  let decode_snapshot text = parse "captured snapshot" text
end
