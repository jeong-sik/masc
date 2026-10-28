module Lifecycle = Keeper_microvm_lifecycle
module Recovery = Fs_compat.Publication_recovery

type snapshot =
  { host_path : string
  ; keeper_name : string
  ; captured : Keeper_github_identity.captured_tool_identity
  }

let path snapshot = snapshot.host_path
let revision snapshot = Keeper_github_identity.captured_revision snapshot.captured
let environment snapshot ~container_config_dir =
  Keeper_github_identity.captured_environment snapshot.captured
    ~keeper_name:snapshot.keeper_name ~container_config_dir

type error =
  | Scope_unavailable of Lifecycle.scope_error
  | Inventory_unavailable of Keeper_microvm_guest_inventory.error
  | Guest_present
  | Snapshot_already_exists
  | Invalid_snapshot of string
  | Filesystem_unavailable of Fs_compat.owned_regular_file_read_error
  | Registry_unavailable of Recovery.registry_error
  | Lane_unavailable of Recovery.lane_open_error
  | Lane_release_failed of { primary : error option; failure : Recovery.lane_release_failure }
  | Invalid_publication_target of Fs_compat.capability_publication_target_error
  | Publication_failed of Fs_compat.capability_write_error
  | Removal_failed of string
  | Filesystem_operation_failed of exn * Printexc.raw_backtrace

let rec error_message = function
  | Scope_unavailable Lifecycle.Scope_closed -> "guest identity lifecycle scope is closed"
  | Scope_unavailable Lifecycle.Other_keeper -> "guest identity lifecycle owner differs"
  | Scope_unavailable Lifecycle.Other_coordinator -> "guest identity lifecycle coordinator differs"
  | Inventory_unavailable error -> Keeper_microvm_guest_inventory.error_message error
  | Guest_present -> "guest identity publication refused: guest name is present"
  | Snapshot_already_exists -> "guest identity snapshot already exists"
  | Invalid_snapshot detail -> "invalid guest identity snapshot: " ^ detail
  | Filesystem_unavailable error -> Fs_compat.owned_regular_file_read_error_to_string error
  | Registry_unavailable error -> Recovery.registry_error_to_string error
  | Lane_unavailable error -> Recovery.lane_open_error_to_string error
  | Lane_release_failed {primary; failure} ->
    let detail = Recovery.lane_release_failure_to_string failure in
    (match primary with None -> detail | Some error -> error_message error ^ "; " ^ detail)
  | Invalid_publication_target error -> Fs_compat.capability_publication_target_error_to_string error
  | Publication_failed error -> Fs_compat.capability_write_error_to_string error
  | Removal_failed detail -> "guest identity removal unconfirmed: " ^ detail
  | Filesystem_operation_failed _ -> "guest identity filesystem operation failed"

open Result.Syntax

let guest_name ~base_path ~keeper_name ~network_mode =
  Keeper_sandbox_container_name.make
    (Keeper_sandbox_container_name.Micro_vm_persistent {base_path; keeper_name; network_mode})
  |> Keeper_sandbox_container_name.to_string

let host_path ~base_path ~keeper_name ~backend ~network_mode =
  Filename.concat
    (Config_dir_resolver.microvm_identity_dir ~base_path
       ~backend:(Keeper_microvm_backend.to_string backend))
    (guest_name ~base_path ~keeper_name ~network_mode)

let components ~base_path ~keeper_name ~backend ~network_mode =
  ["microvm", None; "identity", Some 0o700;
   Keeper_microvm_backend.to_string backend, Some 0o700;
   guest_name ~base_path ~keeper_name ~network_mode, Some 0o500]

(* Only the first shared ancestor may preserve its existing safe mode.
   Credential-exclusive descendants have an exact mode. A missing shared
   ancestor is still created private; None never authorizes chmod/chown. *)
let creation_permissions = function None -> 0o700 | Some permissions -> permissions

let parent_permission_rules = function
  | [] -> []
  | shared :: exclusive ->
    (shared, None) :: List.map (fun leaf -> leaf, Some 0o700) exclusive

let same_identity (left : Unix.stats) (right : Unix.stats) =
  left.st_dev = right.st_dev && left.st_ino = right.st_ino

exception Invalid_directory_permissions
exception Invalid_file_permissions
exception Snapshot_directory_changed

let check_directory ~permissions (stat : Unix.stats) =
  if stat.st_kind <> Unix.S_DIR || stat.st_uid <> Unix.getuid ()
     || stat.st_perm <> permissions || stat.st_perm land 0o022 <> 0
  then raise Invalid_directory_permissions

let filesystem_result result = Result.map_error (fun error -> Filesystem_unavailable error) result

type root = { spelling : string; canonical : string; stat : Unix.stats }

let inspect_root ~base_path =
  Eio_guard.run_in_systhread ~label:"guest-identity-root" (fun () ->
    let spelling = Config_dir_resolver.masc_root ~base_path in
    Fs_compat.with_owned_inventory_root spelling (fun held ->
      let stat = Fs_compat.owned_inventory_root_stat held in
      let original = Unix.lstat spelling in
      if original.st_kind <> Unix.S_DIR || not (same_identity original stat)
         || stat.st_uid <> Unix.getuid () || stat.st_perm land 0o022 <> 0
      then Ok (Error (Invalid_snapshot "unsafe workspace state root"))
      else Ok (Ok {spelling; canonical=Fs_compat.owned_inventory_root_path held; stat}))
    |> filesystem_result |> Result.join)

(* Every recursion holds its parent descriptor through all child reads and
   settlement. Fresh fstat in the settlement callback checks exact final modes,
   rather than treating the opening observation as a permission lease. *)
let with_child ~parent ~parent_permissions ~leaf ~permissions callback =
  let parent_stat = Fs_compat.owned_inventory_root_stat parent in
  let child_stat = ref None in
  let sync_directory fd =
    let stat = Unix.fstat fd in
    let expected =
      if same_identity stat parent_stat then parent_permissions
      else match !child_stat with
        | Some child when same_identity stat child ->
          (if permissions = Some 0o500
              && (stat.st_mtime <> child.st_mtime || stat.st_ctime <> child.st_ctime
                  || stat.st_size <> child.st_size || stat.st_nlink <> child.st_nlink)
           then raise Snapshot_directory_changed);
          (match permissions with None -> child.st_perm | Some permissions -> permissions)
        | Some _ | None -> raise Invalid_directory_permissions in
    check_directory ~permissions:expected stat;
    Unix.fsync fd in
  let directory = Filename.concat (Fs_compat.owned_inventory_root_path parent) leaf in
  let* observed = Fs_compat.with_owned_directory_inventory_if_present
      ~owner_uid:(Unix.getuid ()) ~inventory_root:parent ~sync_directory directory
      (fun child names ->
        let stat = Fs_compat.owned_inventory_root_stat child in
        child_stat := Some stat;
        let observed_permissions = match permissions with
          | None -> stat.st_perm
          | Some permissions -> permissions in
        check_directory ~permissions:observed_permissions stat;
        callback child observed_permissions names)
    |> filesystem_result in
  match observed with None -> Ok None | Some result -> result

let read_file root leaf =
  let* relative = Fs_compat.owned_relative_path [leaf]
    |> Result.map_error (fun _ -> Invalid_snapshot "unsafe file leaf") in
  let* content = Fs_compat.with_owned_inventory_regular_file
      ~owner_uid:(Unix.getuid ()) root relative
      (fun ~file ~parent ~stat ->
        if stat.Unix.st_perm <> 0o400 || stat.st_nlink <> 1
        then raise Invalid_file_permissions;
        let bytes = Bytes.create stat.st_size in
        let rec read offset =
          if offset < Bytes.length bytes then
            let count = Unix.read file bytes offset (Bytes.length bytes - offset) in
            if count = 0 then raise End_of_file else read (offset + count) in
        read 0;
        Unix.fsync file;
        let current = Unix.fstat file in
        if current.st_perm <> 0o400 || current.st_uid <> Unix.getuid () || current.st_nlink <> 1
        then raise Invalid_file_permissions;
        check_directory ~permissions:0o500 (Unix.fstat parent);
        Unix.fsync parent;
        Bytes.unsafe_to_string bytes)
    |> filesystem_result in
  Ok (leaf, content)

let read_snapshot ~root ~base_path ~keeper_name ~backend ~network_mode =
  Eio_guard.run_in_systhread ~label:"guest-identity-load" (fun () ->
    Fs_compat.with_owned_inventory_root root.spelling (fun held ->
      let observed = Fs_compat.owned_inventory_root_stat held in
      let original = Unix.lstat root.spelling in
      if original.st_kind <> Unix.S_DIR || not (same_identity root.stat observed)
         || not (same_identity original observed)
      then Ok (Error (Invalid_snapshot "workspace state root changed"))
      else (
        check_directory ~permissions:root.stat.st_perm observed;
        let rec descend parent parent_permissions = function
          | [] -> Error (Invalid_snapshot "snapshot path is empty")
          | [(leaf, permissions)] ->
            with_child ~parent ~parent_permissions ~leaf ~permissions (fun child _ names ->
              (* The generic inventory's held stat is captured after its
                 enumeration. Enumerate again after our metadata baseline so
                 an entry inserted in that first enumeration/stat gap cannot
                 escape both the names and final metadata checks. *)
              let baseline = Fs_compat.owned_inventory_root_stat child in
              let sync_directory fd =
                let current = Unix.fstat fd in
                check_directory ~permissions:0o500 current;
                if not (same_identity baseline current)
                   || current.st_ctime <> baseline.st_ctime || current.st_mtime <> baseline.st_mtime
                   || current.st_size <> baseline.st_size || current.st_nlink <> baseline.st_nlink
                then raise Snapshot_directory_changed;
                Unix.fsync fd in
              let* second = Fs_compat.with_owned_directory_inventory_if_present
                  ~owner_uid:(Unix.getuid ()) ~inventory_root:child ~sync_directory
                  (Fs_compat.owned_inventory_root_path child) (fun _ names -> names)
                |> filesystem_result in
              if second <> Some names then Error (Invalid_snapshot "snapshot inventory changed")
              else if List.exists (fun name -> not (List.mem name ["hosts.yml"; "config.yml"; "gitconfig"])) names
              then Error (Invalid_snapshot "unknown snapshot entries")
              else
                let* files = List.fold_left (fun acc leaf ->
                  let* files = acc in let* file = read_file child leaf in Ok (file :: files)) (Ok []) names in
                let* captured = Keeper_github_identity.captured_tool_identity_of_files files
                  |> Result.map_error (fun _ -> Invalid_snapshot "noncanonical captured file set") in
                Ok (Some {host_path=host_path ~base_path ~keeper_name ~backend ~network_mode;
                          keeper_name; captured}))
          | (leaf, permissions) :: rest ->
            with_child ~parent ~parent_permissions ~leaf ~permissions
              (fun child observed_permissions _ -> descend child observed_permissions rest) in
        Ok (descend held root.stat.st_perm (components ~base_path ~keeper_name ~backend ~network_mode))))
    |> filesystem_result |> Result.join)

let recovery_owner ~base_path ~keeper_name ~backend ~network_mode =
  let material = `List [`String "guest-identity-v1";
      `String (Keeper_microvm_backend.to_string backend);
      `String (guest_name ~base_path ~keeper_name ~network_mode)] |> Yojson.Safe.to_string in
  "microvm-identity-" ^ Agent_core_sha256.(digest_string material |> to_hex)

let with_recovery ~fs ~root ~owner callback =
  Eio.Path.with_open_dir Eio.Path.(fs / root.canonical) (fun registry_root ->
    let stat = Eio.Path.stat ~follow:true registry_root in
    if stat.dev <> Int64.of_int root.stat.st_dev || stat.ino <> Int64.of_int root.stat.st_ino
    then Error (Invalid_snapshot "workspace state capability changed")
    else Eio.Switch.run @@ fun sw ->
      let* registry = Recovery.open_registry ~sw ~fs ~registry_root
        |> Result.map_error (fun error -> Registry_unavailable error) in
      match Recovery.with_lane ~registry ~owner callback with
      | Error error -> Error (Lane_unavailable error)
      | Ok (Recovery.Lane_released result) -> result
      | Ok (Recovery.Lane_release_failed {value; release_failure}) ->
        Error (Lane_release_failed
          {primary=(match value with Ok _ -> None | Error error -> Some error);
           failure=release_failure}))

let borrow ~coordinator ~scope ~keeper_name callback =
  let guarded () =
    try callback () with
    | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
    | Fs_compat.Capability_write_cancelled _ as cancellation -> raise cancellation
    | error -> Error (Filesystem_operation_failed (error, Printexc.get_raw_backtrace ())) in
  match Lifecycle.with_borrowed_scope coordinator ~scope ~keeper_name guarded with
  | Error error -> Error (Scope_unavailable error)
  | Ok result -> result

let load ~fs ~coordinator ~scope ~base_path ~keeper_name ~backend ~network_mode =
  borrow ~coordinator ~scope ~keeper_name (fun () ->
    let* root = inspect_root ~base_path in
    let owner = recovery_owner ~base_path ~keeper_name ~backend ~network_mode in
    with_recovery ~fs ~root ~owner (fun _ ->
      read_snapshot ~root ~base_path ~keeper_name ~backend ~network_mode))

(* Observations here do not grant mutation authority. Publication first opens
   its Eio capability, then proves that retained capability's identity through
   this no-follow chain and checks it again after the effect and final load. *)
let parent_observation ~root parent_components =
  Eio_guard.run_in_systhread ~label:"guest-identity-parent" (fun () ->
    Fs_compat.with_owned_inventory_root root.spelling (fun held ->
      let original = Unix.lstat root.spelling in
      if original.st_kind <> Unix.S_DIR || not (same_identity root.stat original)
         || not (same_identity root.stat (Fs_compat.owned_inventory_root_stat held))
      then Ok (Error (Invalid_snapshot "workspace state root changed"))
      else
        let rec descend parent parent_permissions = function
          | [] ->
            let stat = Fs_compat.owned_inventory_root_stat parent in
            let sync_directory fd =
              let current = Unix.fstat fd in
              if not (same_identity stat current) then raise Invalid_directory_permissions;
              check_directory ~permissions:parent_permissions current;
              Unix.fsync fd in
            let* observed = Fs_compat.with_owned_directory_inventory_if_present
                ~owner_uid:(Unix.getuid ()) ~inventory_root:parent ~sync_directory
                (Fs_compat.owned_inventory_root_path parent)
                (fun current _ -> Fs_compat.owned_inventory_root_stat current)
              |> filesystem_result in
            (match observed with
             | None -> Error (Invalid_snapshot "bound parent disappeared")
             | Some stat -> Ok (Some stat))
          | (leaf, permissions) :: rest -> with_child ~parent ~parent_permissions ~leaf ~permissions
              (fun child observed_permissions _ -> descend child observed_permissions rest) in
        Ok (descend held root.stat.st_perm (parent_permission_rules parent_components)))
    |> filesystem_result |> Result.join)

let verify_parent_capability ~root ~parent_components parent =
  let capability = Eio.Path.stat ~follow:true parent in
  let* observed = parent_observation ~root parent_components in
  match observed with
  | Some stat when capability.dev = Int64.of_int stat.Unix.st_dev
                   && capability.ino = Int64.of_int stat.st_ino -> Ok ()
  | Some _ | None -> Error (Invalid_snapshot "publication parent capability differs from owned chain")

let publish_directory ~fs ~root ~recovery ~parent_components ~leaf ~permissions
    ~after_publish payload =
  let* target = Fs_compat.capability_publication_target
      ~allowed_root_path:root.canonical
      ~allowed_root_device:(Int64.of_int root.stat.st_dev)
      ~allowed_root_inode:(Int64.of_int root.stat.st_ino)
      ~parent_components ~target_leaf:leaf ~permissions
    |> Result.map_error (fun error -> Invalid_publication_target error) in
  let parent_path = List.fold_left Filename.concat root.canonical parent_components in
  Eio.Path.with_open_dir Eio.Path.(fs / parent_path) (fun parent ->
    let* () = verify_parent_capability ~root ~parent_components parent in
    let* () = Fs_compat.create_capability_directory_exclusive ~recovery ~parent ~target payload
      |> Result.map_error (fun error -> Publication_failed error) in
    let* result = after_publish () in
    let* () = verify_parent_capability ~root ~parent_components parent in
    Ok result)

let publish_if_guest_absent ~fs ~coordinator ~scope ~base_path ~keeper_name ~backend
    ~network_mode ~timeout_sec captured =
  borrow ~coordinator ~scope ~keeper_name (fun () ->
    let* presence = Keeper_microvm_guest_inventory.read ~backend
        ~guest_name:(guest_name ~base_path ~keeper_name ~network_mode) ~timeout_sec
      |> Result.map_error (fun error -> Inventory_unavailable error) in
    match presence with
    | Keeper_microvm_guest_inventory.Present -> Error Guest_present
    | Keeper_microvm_guest_inventory.Absent ->
      let* root = inspect_root ~base_path in
      let owner = recovery_owner ~base_path ~keeper_name ~backend ~network_mode in
      with_recovery ~fs ~root ~owner (fun recovery ->
        let* existing = read_snapshot ~root ~base_path ~keeper_name ~backend ~network_mode in
        match existing with
        | Some _ -> Error Snapshot_already_exists
        | None ->
          let* empty = Fs_compat.directory_payload []
            |> Result.map_error (fun _ -> Invalid_snapshot "invalid empty parent payload") in
          let rec publish_parents prefix = function
            | [] -> Error (Invalid_snapshot "snapshot path is empty")
            | [(leaf, permissions)] ->
              publish_directory ~fs ~root ~recovery ~parent_components:prefix ~leaf
                ~permissions:(creation_permissions permissions)
                ~after_publish:(fun () ->
                  let* snapshot = read_snapshot ~root ~base_path ~keeper_name ~backend ~network_mode in
                  match snapshot with
                  | Some snapshot when String.equal (revision snapshot) (Keeper_github_identity.captured_revision captured) -> Ok snapshot
                  | Some _ | None -> Error (Invalid_snapshot "published snapshot differs from captured identity"))
                (Keeper_github_identity.captured_payload captured)
            | (leaf, permissions) :: rest ->
              let next = prefix @ [leaf] in
              let* exists = parent_observation ~root next in
              let* () = match exists with
                | Some _ -> Ok ()
                | None -> publish_directory ~fs ~root ~recovery ~parent_components:prefix ~leaf
                    ~permissions:(creation_permissions permissions) ~after_publish:(fun () -> Ok ()) empty in
              publish_parents next rest in
          publish_parents [] (components ~base_path ~keeper_name ~backend ~network_mode)))

type removal = Removed | Already_absent

let frozen_directory held (stat : Unix.stats) : Fs_compat.cleanup_directory =
  { path = Fs_compat.owned_inventory_root_path held
  ; device = stat.st_dev
  ; inode = stat.st_ino
  ; owner_uid = stat.st_uid
  ; permissions = stat.st_perm
  }

(* The preparation scopes still require the target to exist while they settle.
   Only after all of them succeed does the canonical remover reopen the frozen
   chain. It verifies every retained identity/mode before each unlink and fsyncs
   the retained parent before reporting absence. *)
let removal_chain ~root ~base_path ~keeper_name ~backend ~network_mode =
  Fs_compat.with_owned_inventory_root root.spelling (fun held ->
    let observed = Fs_compat.owned_inventory_root_stat held in
    let original = Unix.lstat root.spelling in
    if original.st_kind <> Unix.S_DIR || not (same_identity root.stat observed)
       || not (same_identity original observed)
    then Ok (Error (Invalid_snapshot "workspace state root changed"))
    else (
      check_directory ~permissions:root.stat.st_perm observed;
      let prepare_target parent parent_permissions chain leaf =
        let parent_stat = Fs_compat.owned_inventory_root_stat parent in
        let target_stat = ref None in
        let sync_directory fd =
          let current = Unix.fstat fd in
          if same_identity current parent_stat then (
            check_directory ~permissions:parent_permissions current;
            Unix.fsync fd)
          else
            match !target_stat with
            | Some target when same_identity current target ->
              check_directory ~permissions:target.st_perm current;
              (* Absence has already been read in this owned workflow. Use
                 the held exact-inode descriptor, never a pathname chmod. *)
              if current.st_perm = 0o500 then Unix.fchmod fd 0o700;
              let writable = Unix.fstat fd in
              if not (same_identity target writable) then raise Invalid_directory_permissions;
              check_directory ~permissions:0o700 writable;
              Unix.fsync fd
            | Some _ | None -> raise Invalid_directory_permissions in
        let directory = Filename.concat (Fs_compat.owned_inventory_root_path parent) leaf in
        let* found = Fs_compat.with_owned_directory_inventory_if_present
            ~owner_uid:(Unix.getuid ()) ~inventory_root:parent ~sync_directory directory
            (fun target _names ->
              let stat = Fs_compat.owned_inventory_root_stat target in
              (match stat.st_perm with
               | 0o500 | 0o700 -> check_directory ~permissions:stat.st_perm stat
               | _ -> raise Invalid_directory_permissions);
              target_stat := Some stat;
              (* This value escapes only after the held-fd transition and
                 every bound descriptor/path settlement have succeeded. *)
              let frozen = frozen_directory target stat in
              chain @ [{frozen with permissions = 0o700}])
          |> filesystem_result in
        Ok found in
      let rec descend parent parent_permissions chain = function
        | [] -> Error (Invalid_snapshot "snapshot path is empty")
        | [(leaf, _permissions)] -> prepare_target parent parent_permissions chain leaf
        | (leaf, permissions) :: rest ->
          with_child ~parent ~parent_permissions ~leaf ~permissions
            (fun child observed_permissions _ ->
              let stat = Fs_compat.owned_inventory_root_stat child in
              descend child observed_permissions (chain @ [frozen_directory child stat]) rest) in
      Ok (descend held observed.st_perm [frozen_directory held observed]
        (components ~base_path ~keeper_name ~backend ~network_mode))))
  |> filesystem_result |> Result.join

let remove_if_guest_absent ~fs ~coordinator ~scope ~base_path ~keeper_name ~backend
    ~network_mode ~timeout_sec =
  borrow ~coordinator ~scope ~keeper_name (fun () ->
    let* presence = Keeper_microvm_guest_inventory.read ~backend
        ~guest_name:(guest_name ~base_path ~keeper_name ~network_mode) ~timeout_sec
      |> Result.map_error (fun error -> Inventory_unavailable error) in
    match presence with
    | Keeper_microvm_guest_inventory.Present -> Error Guest_present
    | Keeper_microvm_guest_inventory.Absent ->
      let* root = inspect_root ~base_path in
      let owner = recovery_owner ~base_path ~keeper_name ~backend ~network_mode in
      with_recovery ~fs ~root ~owner (fun _ ->
        Eio_guard.run_in_systhread ~label:"guest-identity-remove" (fun () ->
          let* chain = removal_chain ~root ~base_path ~keeper_name ~backend ~network_mode in
          match chain with
          | None -> Ok Already_absent
          | Some chain ->
            Fs_compat.remove_owned_tree chain
            |> Result.map (fun () -> Removed)
            |> Result.map_error (fun detail -> Removal_failed detail))))
