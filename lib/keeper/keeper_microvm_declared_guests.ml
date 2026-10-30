module Strings = Set.Make (String)
module Profile = Keeper_types_profile_sandbox
module Backend = Keeper_microvm_backend
module Loader = Keeper_types_profile_toml_io
module Names = Keeper_sandbox_container_name

type unavailable =
  | Directory_unavailable of Fs_compat.owned_regular_file_read_error
  | Roster_changed
  | Filesystem_unavailable

type file_observation = { leaf : string; stat : Unix.stats; content : string option }
type source =
  { directory : string
  ; stat : Unix.stats
  ; entries : string list
  ; files : file_observation list
  }
type name_knowledge = Known_names | Unknown_names
type t =
  { base_path : string
  ; base_path_hash : string
  ; source : source
  ; expected : Strings.t
  ; invalid_names : Strings.t
  ; invalid_guest_names : Strings.t
  ; name_knowledge : name_knowledge
  }

exception Source_changed

let same_stat (left : Unix.stats) (right : Unix.stats) =
  left.st_dev = right.st_dev && left.st_ino = right.st_ino
  && left.st_kind = right.st_kind && left.st_perm = right.st_perm
  && left.st_uid = right.st_uid && left.st_gid = right.st_gid
  && left.st_nlink = right.st_nlink && left.st_size = right.st_size
  && left.st_mtime = right.st_mtime && left.st_ctime = right.st_ctime
;;

let same_file left right =
  String.equal left.leaf right.leaf && same_stat left.stat right.stat && left.content = right.content
;;

let same_source left right =
  String.equal left.directory right.directory && same_stat left.stat right.stat
  && left.entries = right.entries
  && List.equal same_file left.files right.files
;;

let read_source directory =
  Eio_guard.run_in_systhread ~label:"keeper-guest-declarations" (fun () ->
    try
      let original = Unix.lstat directory in
      if original.st_kind <> Unix.S_DIR then raise Source_changed;
      Fs_compat.with_owned_inventory_root directory (fun held ->
        let canonical = Fs_compat.owned_inventory_root_path held in
        if not (same_stat original (Fs_compat.owned_inventory_root_stat held))
           || not (same_stat original (Unix.lstat directory))
        then raise Source_changed;
        let before = Unix.lstat canonical in
        let list () = Fs_compat.read_owned_directory ~owner_uid:(Unix.getuid ())
            ~inventory_root:held ~ownership_root:canonical canonical in
        Result.bind (list ()) (fun entries ->
          let files = List.filter (fun leaf -> Filename.check_suffix leaf ".toml") entries
            |> List.map (fun leaf ->
              let path = Filename.concat canonical leaf in
              let stat = Unix.lstat path in
              let content = match Fs_compat.load_owned_regular_file_with_snapshot
                  ~owner_uid:(Unix.getuid ()) ~ownership_root:canonical path with
                | Ok (Some file) -> Some file.content
                | Error _ -> None
                | Ok None -> raise Source_changed in
              if not (same_stat stat (Unix.lstat path)) then raise Source_changed;
              { leaf; stat; content }) in
          Result.map (fun after_entries ->
            if entries <> after_entries || not (same_stat before (Unix.lstat canonical))
               || not (same_stat original (Unix.lstat directory))
            then raise Source_changed;
            List.iter (fun (file : file_observation) ->
              if not (same_stat file.stat (Unix.lstat (Filename.concat canonical file.leaf)))
              then raise Source_changed) files;
            { directory; stat = before; entries; files }) (list ())))
      |> Result.map_error (fun error -> Directory_unavailable error)
    with
    | Source_changed -> Error Roster_changed
    | Sys_error _ | Unix.Unix_error _ -> Error Filesystem_unavailable)
;;

let revalidate observation =
  let directory = Config_dir_resolver.keepers_dir_for_base_path ~base_path:observation.base_path in
  if not (String.equal directory observation.source.directory) then Error Roster_changed
  else Result.bind (read_source directory) (fun current ->
    if same_source observation.source current then Ok () else Error Roster_changed)
;;

let guest_name ~base_path ~keeper_name ~network_mode =
  Names.make (Names.Micro_vm_persistent {base_path; keeper_name; network_mode}) |> Names.to_string
;;

let protect_invalid ~base_path name (names, guests) =
  let guests =
    if Keeper_config.validate_name name then
      List.fold_left (fun guests network_mode ->
        Strings.add (guest_name ~base_path ~keeper_name:name ~network_mode) guests)
        guests Profile.all_network_modes
    else guests in
  Strings.add name names, guests
;;

type declaration = Expected of string | Not_apple | Unresolved

let declared_guest ~base_path keeper_name (defaults : Keeper_types_profile.keeper_profile_defaults) =
  match defaults.sandbox_profile with
  | None -> Unresolved
  | Some profile ->
    (match Keeper_meta_contract.missing_required_sandbox_image_error ~keeper_name profile defaults with
     | Some _ -> Unresolved
     | None ->
       match profile with
       | Profile.Docker -> Not_apple
       | Profile.Remote_ssh ->
         (match defaults.remote_endpoint with
          | Some endpoint when String.trim endpoint <> "" -> Not_apple
          | Some _ | None -> Unresolved)
       | Profile.Micro_vm ->
         match Keeper_meta_contract.microvm_backend_of_profile_defaults defaults with
         | None -> Unresolved
         | Some (Backend.Microsandbox | Backend.Nerdctl_kata) -> Not_apple
         | Some Backend.Apple_container ->
           let network_mode = match defaults.network_mode with
             | Some mode -> mode
             | None -> Profile.default_network_mode_for_profile profile in
           Expected (guest_name ~base_path ~keeper_name ~network_mode))
;;

let read ~base_path =
  let directory = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Result.bind (read_source directory) (fun source ->
    let expected, invalid_names, invalid_guest_names, name_knowledge =
      List.fold_left (fun (expected, invalid_names, invalid_guest_names, name_knowledge) file ->
        let stem = Filename.remove_extension file.leaf in
        let protect names =
          let invalid_names, invalid_guest_names = List.fold_left (fun state name ->
            protect_invalid ~base_path name state) (invalid_names, invalid_guest_names) names in
          expected, invalid_names, invalid_guest_names, name_knowledge in
        let unknown_names () =
          let expected, invalid_names, invalid_guest_names, _ = protect [stem] in
          expected, invalid_names, invalid_guest_names, Unknown_names in
        match file.content with
        | None -> unknown_names ()
        | Some content ->
          let path = Filename.concat directory file.leaf in
          match Loader.inspect_keeper_toml_content ~path content with
          | Error _ -> unknown_names ()
          | Ok (keeper_name, defaults) ->
            match declared_guest ~base_path keeper_name defaults with
            | Expected name -> Strings.add name expected, invalid_names, invalid_guest_names, name_knowledge
            | Not_apple -> expected, invalid_names, invalid_guest_names, name_knowledge
            | Unresolved -> protect [stem; keeper_name])
        (Strings.empty, Strings.empty, Strings.empty, Known_names) source.files in
    let observation = {base_path; base_path_hash = Keeper_sandbox_runtime.base_path_hash base_path;
      source; expected; invalid_names; invalid_guest_names; name_knowledge} in
    Result.map (fun () -> observation) (revalidate observation))
;;

type preservation =
  | Roster_unavailable
  | Other_workspace
  | Unscoped_guest
  | Foreign_scope
  | Invalid_keeper_label
  | Declared_guest
  | Invalid_declaration

type candidate = {guest_name : string; keeper_name : string}
type selection = Preserve of preservation | Delete of candidate

let select ~base_path ~declarations (row : Keeper_microvm_guest_inventory.row) =
  match declarations with
  | Error _ -> Preserve Roster_unavailable
  | Ok declarations ->
    let base_path_hash = Keeper_sandbox_runtime.base_path_hash base_path in
    if not (String.equal base_path_hash declarations.base_path_hash) then Preserve Other_workspace
    else match row.scoping_labels with
      | None -> Preserve Unscoped_guest
      | Some labels ->
        if not (String.equal labels.component Keeper_sandbox_runtime_setup.sandbox_component_label_value
          && String.equal labels.base_path_hash base_path_hash
          && String.equal labels.kind Keeper_sandbox_microvm.keeper_vm_container_kind)
        then Preserve Foreign_scope
        else if String.trim row.name = "" || not (Keeper_config.validate_name labels.keeper)
        then Preserve Invalid_keeper_label
        else if Strings.mem row.name declarations.expected then Preserve Declared_guest
        else if Strings.mem labels.keeper declarations.invalid_names
          || Strings.mem row.name declarations.invalid_guest_names
        then Preserve Invalid_declaration
        else match declarations.name_knowledge with
          | Unknown_names -> Preserve Invalid_declaration
          | Known_names -> Delete {guest_name = row.name; keeper_name = labels.keeper}
;;

let unavailable_message = function
  | Directory_unavailable _ -> "keeper declaration directory unavailable"
  | Roster_changed -> "keeper declaration roster changed during observation"
  | Filesystem_unavailable -> "keeper declaration filesystem unavailable"
