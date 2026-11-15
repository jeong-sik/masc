(** Owner discovery and the scoped opening of one owner's store in the
    publication recovery store: list the owners under the registry's [lanes]
    directory, inspect one owner's entry, and run a callback inside a resource
    scope with that owner's store open. [with_store] publishes the whole lane
    in one rename when it is missing and pins an existing lane as found;
    [with_existing_store] only observes a lane that already exists.

    This module is private to [fs_compat_internal] and has no interface file.
    [Capability_recovery_obligation] includes it. *)

open Capability_recovery_record
open Capability_recovery_store_model
open Capability_recovery_store_layout

type owner_discovery_row =
  | Discovered_owner of owner
  | Invalid_owner_name of string

type owner_inspection =
  | Valid_owner
  | Unexpected_owner_kind of
      Eio.File.Stat.kind
  | Missing_owner_entry
  | Owner_entry_unavailable of transition_error

let discover_owners (registry : registry) =
  protect_result ~store_effect:No_record_change (fun () ->
    let names =
      raise_io ~operation:Read_directory ~subject:Lanes_root (fun () ->
        Eio.Path.read_dir registry.lanes)
    in
    List.map
      (fun name ->
         match owner_of_string name with
         | Error _ -> Invalid_owner_name name
         | Ok owner -> Discovered_owner owner)
      names)
;;

let inspect_owner (registry : registry) owner =
  try
    let kind =
      raise_io
        ~operation:Inspect_directory
        ~subject:(Lane_root owner)
        (fun () ->
           Eio.Path.kind
             ~follow:false
             Eio.Path.(registry.lanes / owner_to_string owner))
    in
    match kind with
    | `Directory -> Valid_owner
    | `Not_found -> Missing_owner_entry
    | ( ( `Unknown
        | `Fifo
        | `Character_special
        | `Block_device
        | `Regular_file
        | `Symbolic_link
        | `Socket ) as
        kind ) ->
      Unexpected_owner_kind kind
  with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Transition_failed error -> Owner_entry_unavailable error
  | Store_failure failure ->
    Owner_entry_unavailable
      (transition_error ~store_effect:No_record_change failure)
;;

let open_store_in_scope ~sw ~registry ~owner =
  run_layout (fun () ->
    (match lane_entry_kind ~registry ~owner with
     | `Not_found -> publish_lane ~registry ~owner
     | `Directory
     | `Unknown
     | `Fifo
     | `Character_special
     | `Block_device
     | `Regular_file
     | `Symbolic_link
     | `Socket -> ());
    with_published_directory
      ~parent:registry.lanes
      ~parent_subject:Lanes_root
      ~leaf:(owner_to_string owner)
      ~subject:(Lane_root owner)
    @@ fun lane ->
    let area area =
      Area_available
        (open_published_directory
           ~sw
           ~parent:lane
           ~parent_subject:(Lane_root owner)
           ~leaf:(area_directory_leaf area)
           ~subject:(Area (area, owner)))
    in
    let active = area Active in
    let owned = area Owned in
    let forensic = area Forensic in
    { owner; active; owned; forensic; lane_residues = [] })
;;

let with_store ~registry ~owner ~on_release_failure f =
  let subject = Lane_root owner in
  let outcome =
    Resource_scope.run_resource_only @@ fun sw ->
    Option.iter
      (fun fault ->
         Resource_scope.on_release sw (fun () -> raise fault.fault_exception))
      (matching_lane_scope_release_fault owner);
    match open_store_in_scope ~sw ~registry ~owner with
    | Error _ as error -> error
    | Ok store -> Ok (f store)
  in
  let release_failure =
    match outcome.callback with
    | None -> None
    | Some _ ->
      Option.map
        (fun ({ exception_; backtrace } as raised : Resource_scope.raised) ->
           { failure =
               resource_scope_failure
                 ~operation:Close_directory
                 ~subject
                 raised
           ; exception_
           ; backtrace
           })
        outcome.scope_failure
  in
  Option.iter on_release_failure release_failure;
  match outcome.callback with
  | None ->
    (match outcome.parent_cancellation with
     | Some cancellation ->
       raise_resource_scope_cancellation
         ~default_effect:No_record_change
         ~release_failure:None
         cancellation
     | None ->
       (match outcome.scope_failure with
        | Some raised ->
          raise_resource_scope_exception ~store_effect:No_record_change raised
        | None -> raise Internal_resource_scope_callback_not_entered))
  | Some (Resource_scope.Cancelled cancellation) ->
    raise_resource_scope_cancellation
      ~default_effect:No_record_change
      ~release_failure:(Option.map (fun failure -> failure.failure) release_failure)
      cancellation
  | Some (Resource_scope.Raised raised) ->
    raise_resource_scope_exception
      ?release_failure:(Option.map (fun failure -> failure.failure) release_failure)
      ~store_effect:No_record_change
      raised
  | Some (Resource_scope.Returned result) ->
    (match outcome.parent_cancellation with
     | Some cancellation ->
       let default_effect =
         match result with
         | Ok _ -> No_record_change
         | Error error -> error.store_effect
       in
       raise_resource_scope_cancellation
         ~default_effect
         ~release_failure:(Option.map (fun failure -> failure.failure) release_failure)
         cancellation
     | None ->
       (match result, release_failure with
        | Ok value, None -> Ok (Store_scope_released value)
        | Error error, None -> Error error
        | Error error, Some failure ->
          Error (append_cleanup_failure error failure.failure)
        | Ok value, Some release_failure ->
          Ok
            (Store_scope_release_failed
               { value; release_failure })))
;;

let open_existing_directory ~sw ~parent ~leaf ~subject =
  let path = Eio.Path.(parent / leaf) in
  let lexical =
    raise_io ~operation:Inspect_directory ~subject (fun () ->
      Eio.Path.stat ~follow:false path)
  in
  if lexical.kind <> `Directory
  then
    raise_validation
      ~operation:Inspect_directory
      ~subject
      (Record_kind_mismatch
         { expected = `Directory; actual = lexical.kind });
  let lexical_identity = identity_of_stat lexical in
  let opened =
    raise_io ~operation:Open_directory ~subject (fun () ->
      Eio.Path.open_dir ~sw path)
  in
  let opened = (opened :> Eio.Fs.dir_ty Eio.Path.t) in
  let opened_stat =
    verify_opened_directory ~subject ~lexical_identity opened
  in
  let actual_permissions = opened_stat.perm land 0o7777 in
  if actual_permissions <> directory_permissions
  then
    raise_validation
      ~operation:Inspect_directory
      ~subject
      (Record_permissions_mismatch
         { expected = directory_permissions; actual = actual_permissions });
  opened
;;

let fixed_area_leaf name =
  String.equal name active_directory_leaf
  || String.equal name owned_directory_leaf
  || String.equal name forensic_directory_leaf
;;

let inspect_lane_residue ~lane ~owner name =
  let subject = Lane_entry (owner, name) in
  match
    protect_result ~store_effect:No_record_change (fun () ->
      raise_io ~operation:Inspect_directory ~subject (fun () ->
        Eio.Path.kind ~follow:false Eio.Path.(lane / name)))
  with
  | Error error -> Lane_residue_unavailable { name; error }
  | Ok `Not_found -> Lane_residue_missing { name }
  | Ok
      ( ( `Unknown
        | `Fifo
        | `Character_special
        | `Directory
        | `Block_device
        | `Regular_file
        | `Symbolic_link
        | `Socket ) as
        kind ) ->
    Lane_residue_present { name; kind }
;;

let open_existing_area ~sw ~lane ~owner ~area ~leaf =
  match
    protect_result ~store_effect:No_record_change (fun () ->
      open_existing_directory
        ~sw
        ~parent:lane
        ~leaf
        ~subject:(Area (area, owner)))
  with
  | Ok directory -> Area_available directory
  | Error error -> Area_unavailable error
;;

let with_existing_store ~registry ~owner f =
  let subject = Lane_root owner in
  protect_result ~store_effect:No_record_change (fun () ->
    let outcome =
      Resource_scope.run_resource_only @@ fun sw ->
      let lane =
        open_existing_directory
          ~sw
          ~parent:registry.lanes
          ~leaf:(owner_to_string owner)
          ~subject
      in
      let lane_names =
        raise_io ~operation:Read_directory ~subject (fun () ->
          Eio.Path.read_dir lane)
      in
      let lane_residues =
        List.filter_map
          (fun name ->
             if fixed_area_leaf name
             then None
             else Some (inspect_lane_residue ~lane ~owner name))
          lane_names
      in
      let active =
        open_existing_area
          ~sw
          ~lane
          ~owner
          ~area:Active
          ~leaf:active_directory_leaf
      in
      let owned =
        open_existing_area
          ~sw
          ~lane
          ~owner
          ~area:Owned
          ~leaf:owned_directory_leaf
      in
      let forensic =
        open_existing_area
          ~sw
          ~lane
          ~owner
          ~area:Forensic
          ~leaf:forensic_directory_leaf
      in
      f { owner; active; owned; forensic; lane_residues }
    in
    let release_failure =
      Option.map
        (fun ({ exception_; backtrace } as raised : Resource_scope.raised) ->
           { failure =
               resource_scope_failure
                 ~operation:Close_directory
                 ~subject
                 raised
           ; exception_
           ; backtrace
           })
        outcome.scope_failure
    in
    match outcome.callback with
    | None ->
      (match outcome.parent_cancellation with
       | Some cancellation ->
         Existing_store_scope_cancelled
           { value = None
           ; reason = cancellation.reason
           ; backtrace = cancellation.backtrace
           ; release_failure = None
           }
       | None ->
         (match outcome.scope_failure with
          | Some raised ->
            raise_resource_scope_exception
              ~store_effect:No_record_change
              raised
          | None -> raise Internal_resource_scope_callback_not_entered))
    | Some (Resource_scope.Cancelled cancellation) ->
      Existing_store_scope_cancelled
        { value = None
        ; reason = cancellation.reason
        ; backtrace = cancellation.backtrace
        ; release_failure
        }
    | Some (Resource_scope.Raised raised) ->
      raise_resource_scope_exception
        ?release_failure:(Option.map (fun failure -> failure.failure) release_failure)
        ~store_effect:No_record_change
        raised
    | Some (Resource_scope.Returned value) ->
      (match outcome.parent_cancellation, release_failure with
       | Some cancellation, release_failure ->
         Existing_store_scope_cancelled
           { value = Some value
           ; reason = cancellation.reason
           ; backtrace = cancellation.backtrace
           ; release_failure
           }
       | None, Some release_failure ->
         Existing_store_scope_release_failed { value; release_failure }
       | None, None -> Existing_store_scope_released value))
;;
