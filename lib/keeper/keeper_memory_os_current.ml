(** Keeper-owned current Memory OS snapshot.

    The module is the [Keeper_memory_os_current_*] modules included in order.
    Each one reads only the ones before it. The snapshot reads are defined
    below the includes: no included module calls them. *)

include Keeper_memory_os_current_types
include Keeper_memory_os_current_layout
include Keeper_memory_os_current_range_codec
include Keeper_memory_os_current_receipt_store
include Keeper_memory_os_current_journal
include Keeper_memory_os_current_retraction_plan
include Keeper_memory_os_current_publication
include Keeper_memory_os_current_read_anchor
include Keeper_memory_os_current_update
include Keeper_memory_os_current_revision_evidence
include Keeper_memory_os_current_program_apply
include Keeper_memory_os_current_fact_ops

open Result.Syntax

let read_with_content ~keepers_dir ~keeper_id =
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  let decode_bytes = function
    | None -> Ok None
    | Some content ->
      let+ snapshot = parse snapshot_path content in
      Some (snapshot, content)
  in
  let max_optimistic_attempts = 4 in
  let max_locked_attempts = 8 in
  let rec optimistic attempt =
    (* Snapshot file read and JSON parse run off-domain without holding any
       Memory OS write lock, bracketed by lock-free file identity + publication
       guards so concurrent writers trigger clean retries. *)
    let observed =
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        match publication_read_guard ~keepers_dir ~keeper_id with
        | Error _ -> Ok `Changed
        | Ok () ->
          let* snap_before = stat_identity_result snapshot_path in
          let bytes = Fs_compat.load_file_opt snapshot_path in
          (match publication_read_guard ~keepers_dir ~keeper_id with
           | Error _ -> Ok `Changed
           | Ok () ->
             let* snap_after = stat_identity_result snapshot_path in
             if snap_before = snap_after
             then
               let+ decoded = decode_bytes bytes in
               `Read decoded
             else Ok `Changed))
    in
    match observed with
    | Ok (`Read decoded) -> Ok decoded
    | Ok `Changed when attempt < max_optimistic_attempts ->
      yield_for_concurrent_writer ();
      optimistic (attempt + 1)
    | Ok `Changed -> locked_fallback 0
    | Error _ as err -> err
  and locked_fallback attempt =
    let* () = recover_publication ~keepers_dir ~keeper_id in
    let* copied =
      Keeper_memory_os_aggregate_lock.with_lock ~keepers_dir ~keeper_id (fun () ->
        File_lock_eio.with_lock snapshot_path (fun () ->
          match publication_read_guard ~keepers_dir ~keeper_id with
          | Error detail -> Ok (`Pending detail)
          | Ok () -> Ok (`Bytes (Fs_compat.load_file_opt snapshot_path))))
    in
    match copied with
    | `Bytes bytes ->
      Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
        decode_bytes bytes)
    | `Pending _ when attempt < max_locked_attempts ->
      yield_for_concurrent_writer ();
      locked_fallback (attempt + 1)
    | `Pending detail -> Error detail
  in
  try
    let* () = recover_publication ~keepers_dir ~keeper_id in
    optimistic 0
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error message ->
    Error
      (Printf.sprintf
         "current Memory OS read failed path=%s: %s"
         snapshot_path
         message)
;;

let read_locked_for_keepers_dir ~keepers_dir ~keeper_id =
  let* () = publication_read_guard ~keepers_dir ~keeper_id in
  let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  match Fs_compat.load_file_opt path with
  | None -> Ok None
  | Some text -> Result.map Option.some (parse path text)
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
