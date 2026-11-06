let state_dirname = "official-client-runtime"
let outbox_dirname = "undelivered-tools"
let muse_storage_dirname = "muse-storage"

let state_dir ~base_path ~keeper_name =
  if not (Safe_identifier.is_portable_name keeper_name)
  then Error (Printf.sprintf "invalid official-client Keeper name %S" keeper_name)
  else
    Ok
      (Filename.concat
         (Filename.concat
            (Common.keepers_runtime_dir_of_base ~base_path)
            keeper_name)
         state_dirname)

let outbox_dir ~base_path ~keeper_name =
  Result.map (fun directory -> Filename.concat directory outbox_dirname)
    (state_dir ~base_path ~keeper_name)

let muse_storage_dir ~base_path ~keeper_name =
  Result.map (fun directory -> Filename.concat directory muse_storage_dirname)
    (state_dir ~base_path ~keeper_name)

type outbox_source = Outbox_source of string

let outbox_source ~base_path ~path =
  let directory = Filename.dirname path in
  let keeper_name = Filename.basename (Filename.dirname (Filename.dirname directory)) in
  match outbox_dir ~base_path ~keeper_name with
  | Ok expected when String.equal directory expected
      && String.equal path (Filename.concat expected (Filename.basename path)) ->
      Some (Outbox_source path)
  | Ok _ | Error _ -> None

let outbox_source_path (Outbox_source path) = path
