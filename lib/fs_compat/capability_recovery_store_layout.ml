(** Directory layout operations of the publication recovery store, and the
    failure plumbing around the resource scopes they run in: ensure, open,
    verify, set permissions on and sync the layout directories, and turn the
    exception or cancellation a scope raised into the store's failure and
    transition-error values.

    This module is private to [fs_compat_internal] and has no interface file.
    [Capability_recovery_obligation] includes it. *)

open Capability_recovery_record
open Capability_recovery_store_model

module Resource_scope = Eio_resource_scope

let resource_scope_failure ~operation ~subject
      ({ exception_; backtrace } : Resource_scope.raised)
  =
  make_failure ~operation ~subject exception_ backtrace
;;

let append_cleanup_failure error failure =
  { error with cleanup_failures = error.cleanup_failures @ [ failure ] }
;;

let cancellation_store_evidence ~default_effect reason =
  match reason with
  | Recovery_store_cancelled (original_reason, store_effect, cleanup_failures) ->
    original_reason, store_effect, cleanup_failures, true
  | original_reason -> original_reason, default_effect, [], false
;;

let raise_resource_scope_cancellation
      ~default_effect
      ~release_failure
      ({ reason; backtrace } : Resource_scope.cancelled)
  =
  let original_reason, store_effect, cleanup_failures, had_store_evidence =
    cancellation_store_evidence ~default_effect reason
  in
  let cleanup_failures =
    match release_failure with
    | None -> cleanup_failures
    | Some failure -> cleanup_failures @ [ failure ]
  in
  let reason =
    if had_store_evidence
       || store_effect <> No_record_change
       || cleanup_failures <> []
    then
      Recovery_store_cancelled
        (original_reason, store_effect, cleanup_failures)
    else original_reason
  in
  Printexc.raise_with_backtrace (Eio.Cancel.Cancelled reason) backtrace
;;

let raise_resource_scope_exception
      ?release_failure
      ~store_effect
      ({ exception_; backtrace } : Resource_scope.raised)
  =
  match exception_, release_failure with
  | Transition_failed _, None ->
    Printexc.raise_with_backtrace exception_ backtrace
  | Transition_failed error, Some failure ->
    Printexc.raise_with_backtrace
      (Transition_failed (append_cleanup_failure error failure))
      backtrace
  | Store_failure _, None ->
    Printexc.raise_with_backtrace exception_ backtrace
  | Store_failure failure, Some cleanup_failure ->
    Printexc.raise_with_backtrace
      (Transition_failed
         { store_effect
         ; failure
         ; cleanup_failures = [ cleanup_failure ]
         })
      backtrace
  (* A release failure alongside a foreign exception has no typed home here --
     the arms above carry it into [Transition_failed] and [Store_failure],
     which readers destructure, and this case has no such error to carry it
     in. The callback exception continues with its own backtrace. *)
  | _, _ -> Printexc.raise_with_backtrace exception_ backtrace
;;

let protect_result ~store_effect f =
  try Ok (f ()) with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Transition_failed error -> Error error
  | Store_failure failure -> Error (transition_error ~store_effect failure)
;;

let run_layout f =
  let observed_effect = ref Layout_may_be_incomplete in
  try
    let value = Eio.Cancel.protect f in
    observed_effect := Layout_ready;
    Eio.Fiber.check ();
    Ok value
  with
  | Eio.Cancel.Cancelled reason ->
    let backtrace = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace
      (Eio.Cancel.Cancelled
         (Recovery_store_cancelled (reason, !observed_effect, [])))
      backtrace
  | Transition_failed error -> Error error
  | Store_failure failure ->
    Error
      { store_effect = !observed_effect
      ; failure
      ; cleanup_failures = []
      }
;;

let sync_directory ~subject directory =
  raise_io ~operation:Sync_directory ~subject (fun () ->
    Eio.Path.with_open_in Eio.Path.(directory / ".") @@ fun file ->
    match Eio_unix.Resource.fd_opt file with
    | None -> raise Internal_posix_descriptor_unavailable
    | Some fd ->
      Systhread_host.run
        ~label:"fs-compat-recovery-directory-fsync"
        (fun () ->
           Eio_unix.Fd.use_exn
             "fs-compat-recovery-directory-fsync"
             fd
             Unix.fsync);
      Eio.Fiber.check ())
;;

let verify_opened_directory ~subject ~lexical_identity directory =
  raise_io ~operation:Open_directory ~subject (fun () ->
    Eio.Path.with_open_in Eio.Path.(directory / ".") @@ fun file ->
    let stat = Eio.File.stat file in
    if stat.kind <> `Directory
    then raise (Internal_unexpected_resource_kind stat.kind);
    let opened_identity = identity_of_stat stat in
    if not (equal_identity lexical_identity opened_identity)
    then
      raise
        (Internal_resource_identity_changed
           (lexical_identity, opened_identity));
    stat)
;;

let set_directory_permissions ~subject directory =
  raise_io ~operation:Apply_permissions ~subject (fun () ->
    Eio.Path.with_open_in Eio.Path.(directory / ".") @@ fun file ->
    match Eio_unix.Resource.fd_opt file with
    | None -> raise Internal_posix_descriptor_unavailable
    | Some fd ->
      Systhread_host.run
        ~label:"fs-compat-recovery-directory-fchmod"
        (fun () ->
           Eio_unix.Fd.use_exn
             "fs-compat-recovery-directory-fchmod"
             fd
             (fun unix_fd -> Unix.fchmod unix_fd directory_permissions));
      Eio.Fiber.check ())
;;

let verify_directory_permissions ~subject directory =
  let stat =
    raise_io ~operation:Inspect_directory ~subject (fun () ->
      Eio.Path.with_open_in Eio.Path.(directory / ".") Eio.File.stat)
  in
  let actual = stat.perm land 0o7777 in
  if actual <> directory_permissions
  then
    raise_validation
      ~operation:Inspect_directory
      ~subject
      (Record_permissions_mismatch
         { expected = directory_permissions; actual })
;;

let published_directory_entry ~parent ~leaf ~subject =
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
  path, identity_of_stat lexical
;;

let prepare_directory_entry ~parent ~leaf ~subject =
  let creation =
    raise_io ~operation:Create_directory ~subject (fun () ->
      try
        Eio.Path.mkdir ~perm:directory_permissions Eio.Path.(parent / leaf);
        `Created
      with
      | Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) -> `Existing)
  in
  let path, lexical_identity =
    published_directory_entry ~parent ~leaf ~subject
  in
  path, creation, lexical_identity
;;

let stabilize_directory
      ~parent
      ~parent_subject
      ~subject
      ~creation
      ~lexical_identity
      opened
  =
  let opened_stat =
    verify_opened_directory ~subject ~lexical_identity opened
  in
  let actual_permissions = opened_stat.perm land 0o7777 in
  (match creation with
   | `Created ->
     (* mkdir permissions are filtered through umask. fchmod the pinned
        directory before either directory or parent durability is acknowledged. *)
     set_directory_permissions ~subject opened
   | `Existing ->
     if actual_permissions <> directory_permissions
     then
       raise_validation
         ~operation:Inspect_directory
         ~subject
         (Record_permissions_mismatch
            { expected = directory_permissions; actual = actual_permissions }));
  (* Existing components receive the same barriers as newly created ones. A
     previous attempt may have reached mkdir/fchmod/child-fsync but failed
     before the parent fsync, so merely observing the path cannot prove the
     hierarchy durable. *)
  verify_directory_permissions ~subject opened;
  sync_directory ~subject opened;
  sync_directory ~subject:parent_subject parent
;;

let with_ensured_directory
      ~parent
      ~parent_subject
      ~leaf
      ~subject
      f
  =
  let path, creation, lexical_identity =
    prepare_directory_entry ~parent ~leaf ~subject
  in
  raise_io ~operation:Open_directory ~subject (fun () ->
    Eio.Path.with_open_dir path @@ fun opened ->
    let opened = (opened :> Eio.Fs.dir_ty Eio.Path.t) in
    stabilize_directory
      ~parent
      ~parent_subject
      ~subject
      ~creation
      ~lexical_identity
      opened;
    f opened)
;;

let open_ensured_directory
      ~sw
      ~parent
      ~parent_subject
      ~leaf
      ~subject
  =
  let path, creation, lexical_identity =
    prepare_directory_entry ~parent ~leaf ~subject
  in
  let opened =
    raise_io ~operation:Open_directory ~subject (fun () ->
      Eio.Path.open_dir ~sw path)
  in
  let opened = (opened :> Eio.Fs.dir_ty Eio.Path.t) in
  stabilize_directory
    ~parent
    ~parent_subject
    ~subject
    ~creation
    ~lexical_identity
    opened;
  opened
;;

(* A directory that was published whole is pinned as found: it is never
   created here, and it receives the barriers of an existing component. *)
let with_published_directory
      ~parent
      ~parent_subject
      ~leaf
      ~subject
      f
  =
  let path, lexical_identity =
    published_directory_entry ~parent ~leaf ~subject
  in
  raise_io ~operation:Open_directory ~subject (fun () ->
    Eio.Path.with_open_dir path @@ fun opened ->
    let opened = (opened :> Eio.Fs.dir_ty Eio.Path.t) in
    stabilize_directory
      ~parent
      ~parent_subject
      ~subject
      ~creation:`Existing
      ~lexical_identity
      opened;
    f opened)
;;

let open_published_directory
      ~sw
      ~parent
      ~parent_subject
      ~leaf
      ~subject
  =
  let path, lexical_identity =
    published_directory_entry ~parent ~leaf ~subject
  in
  let opened =
    raise_io ~operation:Open_directory ~subject (fun () ->
      Eio.Path.open_dir ~sw path)
  in
  let opened = (opened :> Eio.Fs.dir_ty Eio.Path.t) in
  stabilize_directory
    ~parent
    ~parent_subject
    ~subject
    ~creation:`Existing
    ~lexical_identity
    opened;
  opened
;;

let lane_entry_kind ~(registry : registry) ~owner =
  raise_io ~operation:Inspect_directory ~subject:(Lane_root owner) (fun () ->
    Eio.Path.kind
      ~follow:false
      Eio.Path.(registry.lanes / owner_to_string owner))
;;

(* NDT-OK: UUID entropy names a lane skeleton that is created exclusively
   under [staging]; a name that is already taken draws another. The name does
   not survive publication and never drives recovery or publication policy. *)
let staged_lane_rng = Domain.DLS.new_key Random.State.make_self_init

let rec stage_lane ~staging ~owner =
  let leaf =
    Uuidm.to_string (Uuidm.v4_gen (Domain.DLS.get staged_lane_rng) ())
  in
  let subject = Staged_lane owner in
  let path, creation, lexical_identity =
    prepare_directory_entry ~parent:staging ~leaf ~subject
  in
  match creation with
  | `Existing -> stage_lane ~staging ~owner
  | `Created ->
    raise_io ~operation:Open_directory ~subject (fun () ->
      Eio.Path.with_open_dir path @@ fun staged ->
      let staged = (staged :> Eio.Fs.dir_ty Eio.Path.t) in
      stabilize_directory
        ~parent:staging
        ~parent_subject:Staging_root
        ~subject
        ~creation
        ~lexical_identity
        staged;
      List.iter
        (fun area ->
           with_ensured_directory
             ~parent:staged
             ~parent_subject:subject
             ~leaf:(area_directory_leaf area)
             ~subject:(Area (area, owner))
             (fun _ -> ()))
        [ Active; Owned; Forensic ]);
    path
;;

(* A lane becomes visible under [lanes] in one rename, with its three areas
   already inside. Building it in place would let a process that dies between
   two mkdirs leave a lane without an area, and reconciliation reads such a
   lane as damage and blocks its owner. A skeleton left under [staging] by a
   process that died before the rename is not a lane and names no owner. *)
let publish_lane ~(registry : registry) ~owner =
  with_ensured_directory
    ~parent:registry.recovery
    ~parent_subject:Recovery_root
    ~leaf:staging_directory_leaf
    ~subject:Staging_root
  @@ fun staging ->
  let staged = stage_lane ~staging ~owner in
  try
    raise_io ~operation:Rename_directory ~subject:(Lane_root owner) (fun () ->
      Eio.Path.rename
        staged
        Eio.Path.(registry.lanes / owner_to_string owner))
  with
  | Store_failure _ as failure ->
    let backtrace = Printexc.get_raw_backtrace () in
    (match lane_entry_kind ~registry ~owner with
     | `Directory ->
       (* Another process published this owner's lane first. *)
       raise_io
         ~operation:Remove_directory
         ~subject:(Staged_lane owner)
         (fun () -> Eio.Path.rmtree staged)
     | `Not_found
     | `Unknown
     | `Fifo
     | `Character_special
     | `Block_device
     | `Regular_file
     | `Symbolic_link
     | `Socket -> Printexc.raise_with_backtrace failure backtrace)
;;

let open_registry_under ~sw ~registry_root =
    let root_stat =
      raise_io ~operation:Inspect_directory ~subject:Registry_root (fun () ->
        Eio.Path.stat ~follow:true registry_root)
    in
    if root_stat.kind <> `Directory
    then
      raise_validation
        ~operation:Inspect_directory
        ~subject:Registry_root
        (Record_kind_mismatch
           { expected = `Directory; actual = root_stat.kind });
    let recovery =
      open_ensured_directory
        ~sw
        ~parent:registry_root
        ~parent_subject:Registry_root
        ~leaf:recovery_directory_leaf
        ~subject:Recovery_root
    in
    let lanes =
      open_ensured_directory
        ~sw
        ~parent:recovery
        ~parent_subject:Recovery_root
        ~leaf:lanes_directory_leaf
        ~subject:Lanes_root
    in
    { recovery; lanes }
;;

let open_registry ~sw ~registry_root =
  run_layout (fun () -> open_registry_under ~sw ~registry_root)
;;

let open_namespaced_registry ~sw ~registry_root ~namespace =
  run_layout (fun () ->
    let leaf = match Capability_leaf.of_string namespace with
      | Some leaf -> Capability_leaf.to_string leaf
      | None ->
        raise_validation ~operation:Create_directory ~subject:Registry_root
          (Invalid_parent_component {index = 0; value = namespace}) in
    with_ensured_directory ~parent:registry_root ~parent_subject:Registry_root
      ~leaf ~subject:Registry_root (fun namespaced ->
        open_registry_under ~sw ~registry_root:namespaced))
;;
