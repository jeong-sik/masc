open Fs_compat_owned_file
open Fs_compat_private_jsonl_transaction

type owned_private_jsonl_permissions = Owned_regular | Private_0600
type owned_private_jsonl_role = Owned_data | Owned_stable_lock
type owned_private_jsonl_read_error =
  | Owned_admission_failed of
      { role : owned_private_jsonl_role; error : owned_regular_file_read_error }
  | Owned_private_permissions_required of
      { role : owned_private_jsonl_role; path : string; actual : int }
  | Owned_transaction_failed of private_jsonl_transaction_error

let read_owned_private_jsonl_with_io ?parent_lstat ~io ~owner_uid ~ownership_root
      ~permissions path ~after =
  let admit_leaf role leaf =
    match observe_owned_regular_file_blocking ~single_link:true ?parent_lstat
      ~owner_uid ~ownership_root leaf with
    | Error error -> Error (Owned_admission_failed { role; error })
    | Ok observed ->
      (match permissions, observed with
       | Private_0600, Some observed when observed.permissions <> 0o600 ->
         Error (Owned_private_permissions_required
           { role; path = leaf; actual = observed.permissions })
       | (Owned_regular | Private_0600), (None | Some _) -> Ok ())
  in
  let admit () =
    let open Result.Syntax in
    let* () = admit_leaf Owned_data path in
    admit_leaf Owned_stable_lock (private_jsonl_requested_lock_path path)
  in
  let result =
    with_private_jsonl_admitted_stable_lock ~io
      ~success:(fun snapshot -> Snapshot_succeeded snapshot) ~admit
      ~map_transaction_error:(fun error -> Owned_transaction_failed error) path
      (fun ~dir:_ ~path ->
        Fs_compat_private_jsonl_write.read_private_jsonl_snapshot_locked ~io path ~after)
  in
  (match Fs_compat_base_io.execution_context () with
   | Non_eio -> ()
   | Eio_fiber -> Eio.Fiber.check ());
  result
;;

let read_owned_private_jsonl_durable_locked_result ~owner_uid ~ownership_root
      ~permissions path ~after =
  read_owned_private_jsonl_with_io ~io:private_jsonl_transaction_unix_io
    ~owner_uid ~ownership_root ~permissions path ~after
;;

module Owned_private_jsonl_for_testing = struct
  let read ~parent_lstat ~io ~owner_uid ~ownership_root ~permissions path ~after =
    read_owned_private_jsonl_with_io ~parent_lstat ~io
      ~owner_uid ~ownership_root ~permissions path ~after

  let path_mutex_available path =
    Option.is_some (Fs_compat_base_io.try_with_append_path_mutex path (fun () -> ()))
end
