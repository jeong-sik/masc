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
  try
    let* () = recover_publication ~keepers_dir ~keeper_id in
    let* () = publication_read_guard ~keepers_dir ~keeper_id in
    let observed = match Fs_compat.load_file_opt snapshot_path with
    | None -> Ok None
    | Some content ->
      let+ snapshot = parse snapshot_path content in
      Some (snapshot, content) in
    let* () = publication_read_guard ~keepers_dir ~keeper_id in
    observed
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
