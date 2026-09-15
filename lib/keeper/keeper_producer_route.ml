type t =
  | Keeper of string
  | No_keeper

(* [Keeper_meta_store.read_meta] folds a missing file and a file this binary
   cannot decode into the same [Ok None]. Only the first means there is no
   Keeper; the second is a Keeper whose meta the boot path re-materialises,
   so the presence is read with the two cases kept apart. *)
let resolve ~(config : Workspace_utils_backend_setup.config) producer =
  match
    Keeper_registry_lookup.find_by_name_in_base_path
      ~base_path:config.Workspace.base_path
      producer
  with
  | Some entry -> Ok (Keeper entry.name)
  | None ->
    let name = String.trim producer in
    if String.equal name ""
    then Ok No_keeper
    else (
      match
        Keeper_meta_store.read_meta_file_path_presence
          ~ownership_root:config.Workspace.base_path
          (Keeper_types_profile.keeper_meta_path config name)
      with
      | Ok (Keeper_meta_store.Meta_present _) -> Ok (Keeper name)
      | Ok Keeper_meta_store.Meta_absent -> Ok No_keeper
      | Ok (Keeper_meta_store.Meta_not_current detail) ->
        Error
          (Printf.sprintf
             "keeper meta for %s is present but this binary does not decode it: %s"
             name
             detail)
      | Error detail -> Error detail)
;;

(* The same question asked without writing anything.

   [read_meta_file_path_presence] is not a pure read: a meta whose enumerated
   fields are off-canon is repaired in place, which is a durable atomic rewrite
   and an fsync of another Keeper's file (#28844). Under the backlog lock that
   is not slowness, it is correctness — the lock is a lease with a wall-clock
   expiry, and an fsync widens the window where it expires while still held.
   Against a writer that keeps corrupting the file, that write repeats every
   interval.

   So the in-lock answer comes from the read-only decoder, and every case that
   is not "there is no file" answers "routable". That is the direction that
   costs nothing: the release is skipped and the obligation is kept, and the
   next interval asks again through {!resolve}, which may repair, route or
   report. Releasing a task on a guess would not be recoverable the same way. *)
let has_no_queue_without_writing
      ~(config : Workspace_utils_backend_setup.config)
      producer
  =
  match
    Keeper_registry_lookup.find_by_name_in_base_path
      ~base_path:config.Workspace.base_path
      producer
  with
  | Some _ -> false
  | None ->
    let name = String.trim producer in
    if String.equal name ""
    then true
    else (
      match
        Keeper_meta_store.read_meta_file_path_read_only
          ~ownership_root:config.Workspace.base_path
          (Keeper_types_profile.keeper_meta_path config name)
      with
      | Ok None -> true
      | Ok (Some _) -> false
      | Error (Keeper_meta_store.Unreadable _ | Keeper_meta_store.Not_current _) ->
        false)
;;
