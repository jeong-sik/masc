(* See [atomic_write.mli] for the contract. *)

(* Durable atomic write: tmp → fsync(tmp) → rename → fsync(parent dir).
   Without the fsync pair, a crash between the rename and the kernel's
   dirty-page flush can leave the target truncated or zero-length —
   observed on backlog.json after an abrupt shutdown (2026-04-18). *)
let fsync_path path =
  let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
  Stdlib.Fun.protect
    ~finally:(fun () ->
      try Unix.close fd with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Stdlib.Printf.eprintf
          "[fs_compat] fsync_path close failed: %s\n%!"
          (Printexc.to_string exn))
    (fun () ->
      try Unix.fsync fd with
      | Unix.Unix_error ((Unix.EINVAL | Unix.EOPNOTSUPP), _, _) ->
        (* Some filesystems (tmpfs on some kernels) reject fsync. The data
           is still durable to the extent the underlying FS offers. *)
        ())
;;

(* #10205 finding 2: keep the atomic-tmp filename shape in one place
   so the writer ([save_file_atomic]) and the orphan-sweep matcher
   ([is_atomic_orphan_name]) cannot drift independently. A
   prefix/suffix change on one side without the other would cause
   the sweep to either miss live orphans or scoop unrelated tmp
   files. *)
let atomic_tmp_prefix = ".atomic_"
let atomic_tmp_suffix = ".tmp"

let open_atomic_temp_file ~temp_dir () =
  Stdlib.Filename.open_temp_file
    ~temp_dir
    atomic_tmp_prefix
    atomic_tmp_suffix
;;

type capability_write_intent =
  | Atomic_replace
  | Create_exclusive

type capability_write_stage =
  | Validate_leaf
  | Acquire_mutation_lease
  | Create_staging_directory
  | Inspect_staging_directory
  | Acquire_staging_directory
  | Apply_staging_directory_permissions
  | Verify_staging_directory_identity
  | Create_staging_entry
  | Create_target_entry
  | Inspect_open_resource
  | Write_payload
  | Apply_permissions
  | Sync_payload
  | Close_payload
  | Verify_entry_identity
  | Publish_replace
  | Sync_staging_directory
  | Sync_parent
  | Remove_staging_directory
  | Close_staging_directory
  | Cleanup_close
  | Cleanup_verify_identity
  | Cleanup_unlink
  | Cleanup_sync_staging_directory
  | Cleanup_verify_staging_directory_identity
  | Cleanup_remove_staging_directory
  | Cleanup_close_staging_directory
  | Cleanup_sync_parent

type capability_write_target_effect =
  | Target_unchanged
  | Target_created
  | Target_created_incomplete
  | Target_replaced
  | Target_state_unknown

type capability_write_operation_failure =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

type capability_write_payload_failure =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  ; bytes_written : int
  }

type capability_write_cause =
  | Invalid_leaf of string
  | Mutation_contended
  | Posix_descriptor_unavailable
  | Unexpected_resource_kind of Eio.File.Stat.kind
  | Resource_identity_unavailable
  | Resource_identity_changed
  | Payload_write_failed of capability_write_payload_failure
  | Operation_failed of capability_write_operation_failure

type capability_write_failure =
  { stage : capability_write_stage
  ; cause : capability_write_cause
  }

type capability_write_error =
  { intent : capability_write_intent
  ; target_effect : capability_write_target_effect
  ; failure : capability_write_failure
  ; cleanup_failures : capability_write_failure list
  }

type capability_directory_sync_error =
  { failure : capability_write_failure
  ; cleanup_failures : capability_write_failure list
  }

type capability_write_cancellation =
  { intent : capability_write_intent
  ; target_effect : capability_write_target_effect
  ; cleanup_failures : capability_write_failure list
  }

exception Capability_write_failed of
  capability_write_failure * capability_write_failure list

exception Capability_write_cancelled of exn * capability_write_cancellation

exception Parent_sync_cleanup_failed_on_cancellation of
  exn * capability_write_failure list

let capability_write_intent_to_string = function
  | Atomic_replace -> "atomic_replace"
  | Create_exclusive -> "create_exclusive"
;;

let capability_write_stage_to_string = function
  | Validate_leaf -> "validate_leaf"
  | Acquire_mutation_lease -> "acquire_mutation_lease"
  | Create_staging_directory -> "create_staging_directory"
  | Inspect_staging_directory -> "inspect_staging_directory"
  | Acquire_staging_directory -> "acquire_staging_directory"
  | Apply_staging_directory_permissions ->
    "apply_staging_directory_permissions"
  | Verify_staging_directory_identity ->
    "verify_staging_directory_identity"
  | Create_staging_entry -> "create_staging_entry"
  | Create_target_entry -> "create_target_entry"
  | Inspect_open_resource -> "inspect_open_resource"
  | Write_payload -> "write_payload"
  | Apply_permissions -> "apply_permissions"
  | Sync_payload -> "sync_payload"
  | Close_payload -> "close_payload"
  | Verify_entry_identity -> "verify_entry_identity"
  | Publish_replace -> "publish_replace"
  | Sync_staging_directory -> "sync_staging_directory"
  | Sync_parent -> "sync_parent"
  | Remove_staging_directory -> "remove_staging_directory"
  | Close_staging_directory -> "close_staging_directory"
  | Cleanup_close -> "cleanup_close"
  | Cleanup_verify_identity -> "cleanup_verify_identity"
  | Cleanup_unlink -> "cleanup_unlink"
  | Cleanup_sync_staging_directory -> "cleanup_sync_staging_directory"
  | Cleanup_verify_staging_directory_identity ->
    "cleanup_verify_staging_directory_identity"
  | Cleanup_remove_staging_directory -> "cleanup_remove_staging_directory"
  | Cleanup_close_staging_directory -> "cleanup_close_staging_directory"
  | Cleanup_sync_parent -> "cleanup_sync_parent"
;;

let capability_write_target_effect_to_string = function
  | Target_unchanged -> "target_unchanged"
  | Target_created -> "target_created"
  | Target_created_incomplete -> "target_created_incomplete"
  | Target_replaced -> "target_replaced"
  | Target_state_unknown -> "target_state_unknown"
;;

let capability_write_cause_to_string = function
  | Invalid_leaf leaf -> Printf.sprintf "invalid leaf component: %S" leaf
  | Mutation_contended -> "another cooperative writer owns this entry"
  | Posix_descriptor_unavailable -> "POSIX descriptor unavailable"
  | Unexpected_resource_kind kind ->
    Format.asprintf "unexpected resource kind: %a" Eio.File.Stat.pp_kind kind
  | Resource_identity_unavailable -> "resource identity unavailable"
  | Resource_identity_changed -> "resource identity changed"
  | Payload_write_failed { exception_; bytes_written; _ } ->
    Printf.sprintf
      "payload write failed after %d bytes: %s"
      bytes_written
      (Printexc.to_string exception_)
  | Operation_failed { exception_; _ } -> Printexc.to_string exception_
;;

let capability_write_failure_to_string failure =
  Printf.sprintf
    "stage=%s reason=%s"
    (capability_write_stage_to_string failure.stage)
    (capability_write_cause_to_string failure.cause)
;;

let capability_write_error_to_string (error : capability_write_error) =
  let cleanup =
    match error.cleanup_failures with
    | [] -> ""
    | failures ->
      failures
      |> List.map capability_write_failure_to_string
      |> String.concat "; "
      |> Printf.sprintf " cleanup_failures=[%s]"
  in
  Printf.sprintf
    "intent=%s target_effect=%s failure=(%s)%s"
    (capability_write_intent_to_string error.intent)
    (capability_write_target_effect_to_string error.target_effect)
    (capability_write_failure_to_string error.failure)
    cleanup
;;

let capability_directory_sync_error_to_string
      (error : capability_directory_sync_error)
  =
  let cleanup =
    match error.cleanup_failures with
    | [] -> ""
    | failures ->
      failures
      |> List.map capability_write_failure_to_string
      |> String.concat "; "
      |> Printf.sprintf " cleanup_failures=[%s]"
  in
  Printf.sprintf
    "failure=(%s)%s"
    (capability_write_failure_to_string error.failure)
    cleanup
;;

let operation_failure stage exception_ backtrace =
  { stage; cause = Operation_failed { exception_; backtrace } }
;;

let raise_failure stage cause =
  raise (Capability_write_failed ({ stage; cause }, []))
;;

let run_stage ~before_stage stage f =
  try
    before_stage stage;
    f ()
  with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Capability_write_failed _ as failure -> raise failure
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    raise
      (Capability_write_failed
         (operation_failure stage exception_ backtrace, []))
;;

let capture_cleanup ~before_stage stage f =
  try
    before_stage stage;
    f ();
    []
  with
  | Capability_write_failed (failure, additional) -> failure :: additional
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    [ operation_failure stage exception_ backtrace ]
;;

type resource_identity =
  { dev : int64
  ; ino : int64
  }

let same_resource_identity expected actual =
  Int64.equal expected.dev actual.Eio.File.Stat.dev
  && Int64.equal expected.ino actual.Eio.File.Stat.ino
;;

let identity_of_open_resource ~before_stage ~stage ~expected_kind file =
  let stat = run_stage ~before_stage stage (fun () -> Eio.File.stat file) in
  if stat.kind <> expected_kind
  then raise_failure stage (Unexpected_resource_kind stat.kind)
  else { dev = stat.dev; ino = stat.ino }
;;

let identity_of_open_file ~before_stage file =
  identity_of_open_resource
    ~before_stage
    ~stage:Inspect_open_resource
    ~expected_kind:`Regular_file
    file
;;

(* UUID entropy names an exclusive per-write staging directory;
   correctness comes from exclusive mkdir and typed collision retry, and the
   nonce never drives publication policy. NDT-OK *)
let capability_staging_rng = Domain.DLS.new_key Random.State.make_self_init
let capability_staging_directory_prefix = ".masc_atomic_stage_"
let capability_staging_directory_suffix = ".dir"
let capability_staging_payload_leaf = "payload"
let capability_staging_directory_permissions = 0o700

let fresh_capability_staging_directory_name () =
  let generator = Uuidm.v4_gen (Domain.DLS.get capability_staging_rng) in
  let nonce = generator () |> Uuidm.to_string in
  Printf.sprintf
    "%s%s%s"
    capability_staging_directory_prefix
    nonce
    capability_staging_directory_suffix
;;

let validate_leaf ~before_stage leaf =
  run_stage ~before_stage Validate_leaf (fun () ->
    match Capability_leaf.of_string leaf with
    | Some leaf -> leaf
    | None -> raise_failure Validate_leaf (Invalid_leaf leaf))
;;

let set_open_file_permissions ~before_stage file permissions =
  run_stage ~before_stage Apply_permissions (fun () ->
    match Eio_unix.Resource.fd_opt file with
    | None -> raise_failure Apply_permissions Posix_descriptor_unavailable
    | Some fd ->
      Eio_unix.run_in_systhread ~label:"fs-compat-capability-fchmod" (fun () ->
        Eio_unix.Fd.use_exn "fs-compat-capability-fchmod" fd (fun unix_fd ->
          Unix.fchmod unix_fd permissions));
      Eio.Fiber.check ())
;;

let set_open_directory_permissions ~before_stage directory_file =
  run_stage ~before_stage Apply_staging_directory_permissions (fun () ->
    match Eio_unix.Resource.fd_opt directory_file with
    | None ->
      raise_failure
        Apply_staging_directory_permissions
        Posix_descriptor_unavailable
    | Some fd ->
      Eio_unix.run_in_systhread
        ~label:"fs-compat-capability-staging-directory-fchmod"
        (fun () ->
           Eio_unix.Fd.use_exn
             "fs-compat-capability-staging-directory-fchmod"
             fd
             (fun unix_fd ->
                Unix.fchmod unix_fd capability_staging_directory_permissions));
      Eio.Fiber.check ())
;;

let sync_open_directory_file ~before_stage ~stage directory_file =
  run_stage ~before_stage stage (fun () ->
    match Eio_unix.Resource.fd_opt directory_file with
    | None -> raise_failure stage Posix_descriptor_unavailable
    | Some fd ->
      Eio_unix.run_in_systhread
        ~label:"fs-compat-capability-staging-directory-fsync"
        (fun () ->
           Eio_unix.Fd.use_exn
             "fs-compat-capability-staging-directory-fsync"
             fd
             Unix.fsync))
;;

let write_open_file_payload ~before_stage file content =
  run_stage ~before_stage Write_payload (fun () ->
    match
      Blocking_write.write_string
        ~label:"fs-compat-capability-write"
        file
        content
    with
    | Ok () -> Eio.Fiber.check ()
    | Error Blocking_write.Open_file_posix_descriptor_unavailable ->
      raise_failure Write_payload Posix_descriptor_unavailable
    | Error
        (Blocking_write.Open_file_operation_failed
          { exception_; backtrace; bytes_written }) ->
      raise
        (Capability_write_failed
           ( { stage = Write_payload
             ; cause =
                 Payload_write_failed
                   { exception_; backtrace; bytes_written }
             }
           , [] )))
;;

let sync_parent_capability ~before_stage ~stage ~sw parent =
  let directory_file = ref None in
  let close_directory () =
    match !directory_file with
    | None -> []
    | Some file ->
      let failures =
        try
          Eio.Resource.close file;
          []
        with
        | exception_ ->
          let backtrace = Printexc.get_raw_backtrace () in
          [ operation_failure stage exception_ backtrace ]
      in
      directory_file := None;
      failures
  in
  try
    before_stage stage;
    let file = Eio.Path.open_in ~sw Eio.Path.(parent / ".") in
    directory_file := Some file;
    (match Eio_unix.Resource.fd_opt file with
     | None -> raise_failure stage Posix_descriptor_unavailable
     | Some fd ->
       Eio_unix.run_in_systhread ~label:"fs-compat-capability-dir-fsync" (fun () ->
         Eio_unix.Fd.use_exn "fs-compat-capability-dir-fsync" fd Unix.fsync));
    let close_failures = close_directory () in
    (match close_failures with
     | [] -> ()
     | failure :: additional ->
       raise (Capability_write_failed (failure, additional)))
  with
  | Eio.Cancel.Cancelled reason as cancellation ->
    let backtrace = Printexc.get_raw_backtrace () in
    let close_failures = close_directory () in
    if close_failures = []
    then Printexc.raise_with_backtrace cancellation backtrace
    else
      Printexc.raise_with_backtrace
        (Eio.Cancel.Cancelled
           (Parent_sync_cleanup_failed_on_cancellation
              (reason, close_failures)))
        backtrace
  | Capability_write_failed (failure, additional) ->
    let close_failures = close_directory () in
    raise
      (Capability_write_failed
         (failure, additional @ close_failures))
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    let close_failures = close_directory () in
    raise
      (Capability_write_failed
         (operation_failure stage exception_ backtrace, close_failures))
;;

let close_open_resource ~before_stage ~stage open_resource =
  match !open_resource with
  | None -> ()
  | Some resource ->
    run_stage ~before_stage stage (fun () -> Eio.Resource.close resource);
    open_resource := None
;;

let close_open_entry ~before_stage open_file =
  close_open_resource ~before_stage ~stage:Close_payload open_file
;;

let verify_path_identity
      ~before_stage
      ~stage
      ~expected_kind
      path
      identity
  =
  run_stage ~before_stage stage (fun () ->
    match !identity with
    | None -> raise_failure stage Resource_identity_unavailable
    | Some expected ->
      let actual = Eio.Path.stat ~follow:false path in
      if
        actual.kind <> expected_kind
        || not (same_resource_identity expected actual)
      then raise_failure stage Resource_identity_changed)
;;

let verify_entry_identity ~before_stage ~stage entry identity =
  verify_path_identity
    ~before_stage
    ~stage
    ~expected_kind:`Regular_file
    entry
    identity
;;

let cleanup_open_resource ~before_stage ~stage open_resource =
  match !open_resource with
  | None -> []
  | Some resource ->
    let failures =
      capture_cleanup ~before_stage stage (fun () ->
        Eio.Resource.close resource)
    in
    open_resource := None;
    failures
;;

let cleanup_open_file ~before_stage open_file =
  cleanup_open_resource ~before_stage ~stage:Cleanup_close open_file
;;

let cleanup_parent_if_dirty ~before_stage ~sw ~parent parent_dirty =
  if not !parent_dirty
  then []
  else
    let failures =
      capture_cleanup ~before_stage Cleanup_sync_parent (fun () ->
        sync_parent_capability
          ~before_stage:(fun _ -> ())
          ~stage:Cleanup_sync_parent
          ~sw
          parent)
    in
    if failures = [] then parent_dirty := false;
    failures
;;

let cleanup_owned_staging_directory
      ~before_stage
      ~sw
      ~parent
      ~staging_path
      ~staging_directory_file
      ~staging_directory_identity
      ~staging_directory_created
      ~staging_directory_removed
      ~payload_entry
      ~payload_file
      ~payload_identity
      ~payload_created
      ~payload_published
      ~parent_dirty
  =
  Eio.Cancel.protect (fun () ->
    let failures = ref (cleanup_open_file ~before_stage payload_file) in
    let add additional = failures := !failures @ additional in
    let payload_absent =
      if (not !payload_created) || !payload_published
      then true
      else (
        let identity_failures =
          capture_cleanup ~before_stage Cleanup_verify_identity (fun () ->
            match !payload_entry, !payload_identity with
            | Some entry, Some expected ->
              let actual = Eio.Path.stat ~follow:false entry in
              if
                actual.kind <> `Regular_file
                || not (same_resource_identity expected actual)
              then raise_failure Cleanup_verify_identity Resource_identity_changed
            | None, _ | _, None ->
              raise_failure
                Cleanup_verify_identity
                Resource_identity_unavailable)
        in
        add identity_failures;
        if identity_failures <> []
        then false
        else (
          let unlink_failures =
            capture_cleanup ~before_stage Cleanup_unlink (fun () ->
              match !payload_entry with
              | None ->
                raise_failure Cleanup_unlink Resource_identity_unavailable
              | Some entry -> Eio.Path.unlink entry)
          in
          add unlink_failures;
          if unlink_failures = [] then payload_created := false;
          unlink_failures = []))
    in
    let staging_sync_failures =
      if (not !staging_directory_created) || !staging_directory_removed
      then []
      else
        capture_cleanup ~before_stage Cleanup_sync_staging_directory (fun () ->
          match !staging_directory_file with
          | None ->
            raise_failure
              Cleanup_sync_staging_directory
              Resource_identity_unavailable
          | Some directory_file ->
            sync_open_directory_file
              ~before_stage:(fun _ -> ())
              ~stage:Cleanup_sync_staging_directory
              directory_file)
    in
    add staging_sync_failures;
    add
      (cleanup_open_resource
         ~before_stage
         ~stage:Cleanup_close_staging_directory
         staging_directory_file);
    let staging_identity_failures =
      if (not !staging_directory_created) || !staging_directory_removed
      then []
      else
        capture_cleanup
          ~before_stage
          Cleanup_verify_staging_directory_identity
          (fun () ->
             match !staging_path, !staging_directory_identity with
             | Some path, Some expected ->
               let actual = Eio.Path.stat ~follow:false path in
               if
                 actual.kind <> `Directory
                 || not (same_resource_identity expected actual)
               then
                 raise_failure
                   Cleanup_verify_staging_directory_identity
                   Resource_identity_changed
             | None, _ | _, None ->
               raise_failure
                 Cleanup_verify_staging_directory_identity
                 Resource_identity_unavailable)
    in
    add staging_identity_failures;
    if
      !staging_directory_created
      && not !staging_directory_removed
      && payload_absent
      && staging_sync_failures = []
      && staging_identity_failures = []
    then (
      let removal_failures =
        capture_cleanup ~before_stage Cleanup_remove_staging_directory (fun () ->
          match !staging_path with
          | None ->
            raise_failure
              Cleanup_remove_staging_directory
              Resource_identity_unavailable
          | Some path -> Eio.Path.rmdir path)
      in
      add removal_failures;
      if removal_failures = []
      then (
        staging_directory_removed := true;
        parent_dirty := true));
    add (cleanup_parent_if_dirty ~before_stage ~sw ~parent parent_dirty);
    !failures)
;;

let publish_capability_file_with
      ~before_stage
      ~parent
      ~leaf
      ~intent
      ~permissions
  content
  =
  try
    let leaf = validate_leaf ~before_stage leaf in
    let leaf_name = Capability_leaf.to_string leaf in
    Eio.Switch.run @@ fun sw ->
    let target = Eio.Path.(parent / leaf_name) in
    let mutation_lease =
      run_stage ~before_stage Acquire_mutation_lease (fun () ->
        let parent_stat = Eio.Path.stat ~follow:true parent in
        if parent_stat.kind <> `Directory
        then
          raise_failure
            Acquire_mutation_lease
            (Unexpected_resource_kind parent_stat.kind);
        match
          Capability_mutation_lease.try_acquire
            ~parent_dev:parent_stat.dev
            ~parent_ino:parent_stat.ino
            ~leaf
        with
        | Some lease -> lease
        | None -> raise_failure Acquire_mutation_lease Mutation_contended)
    in
    Fun.protect
      ~finally:(fun () -> Capability_mutation_lease.release mutation_lease)
    @@ fun () ->
    let staging_path = ref None in
    let staging_directory = ref None in
    let staging_directory_file = ref None in
    let staging_directory_identity = ref None in
    let staging_directory_created = ref false in
    let staging_directory_removed = ref false in
    let payload_entry = ref None in
    let open_file = ref None in
    let identity = ref None in
    let entry_created = ref false in
    let target_effect = ref Target_unchanged in
    let published = ref false in
    let parent_dirty = ref false in
    let create_stage =
      match intent with
      | Atomic_replace -> Create_staging_directory
      | Create_exclusive -> Create_target_entry
    in
    let cleanup () =
      match intent with
      | Atomic_replace ->
        cleanup_owned_staging_directory
          ~before_stage
          ~sw
          ~parent
          ~staging_path
          ~staging_directory_file
          ~staging_directory_identity
          ~staging_directory_created
          ~staging_directory_removed
          ~payload_entry
          ~payload_file:open_file
          ~payload_identity:identity
          ~payload_created:entry_created
          ~payload_published:published
          ~parent_dirty
      | Create_exclusive ->
        Eio.Cancel.protect (fun () ->
          let close_failures = cleanup_open_file ~before_stage open_file in
          close_failures
          @ cleanup_parent_if_dirty ~before_stage ~sw ~parent parent_dirty)
    in
    let error ~failure ~additional =
      let cleanup_failures = additional @ cleanup () in
      let target_effect =
        match intent with
        | Atomic_replace -> !target_effect
        | Create_exclusive -> !target_effect
      in
      Error { intent; target_effect; failure; cleanup_failures }
    in
    (try
       let create_owned_staging_directory () =
         let rec create_fresh () =
           let path =
             Eio.Path.(parent / fresh_capability_staging_directory_name ())
           in
           let result =
             Eio.Cancel.protect (fun () ->
               let creation =
                 run_stage ~before_stage Create_staging_directory (fun () ->
                   try
                     Eio.Path.mkdir
                       ~perm:capability_staging_directory_permissions
                       path;
                     `Created
                   with
                   | Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) ->
                     `Collision)
               in
               match creation with
               | `Collision -> `Collision
               | `Created ->
                 staging_path := Some path;
                 staging_directory_created := true;
                 parent_dirty := true;
                 let created_identity =
                   run_stage ~before_stage Inspect_staging_directory (fun () ->
                     let lexical = Eio.Path.stat ~follow:false path in
                     if lexical.kind <> `Directory
                     then
                       raise_failure
                         Inspect_staging_directory
                         (Unexpected_resource_kind lexical.kind);
                     { dev = lexical.dev; ino = lexical.ino })
                 in
                 staging_directory_identity := Some created_identity;
                 run_stage ~before_stage Acquire_staging_directory (fun () ->
                   let directory = Eio.Path.open_dir ~sw path in
                   staging_directory := Some directory;
                   let directory_file =
                     Eio.Path.open_in ~sw Eio.Path.(directory / ".")
                   in
                   staging_directory_file := Some directory_file;
                   let opened = Eio.File.stat directory_file in
                   if opened.kind <> `Directory
                   then
                     raise_failure
                       Acquire_staging_directory
                       (Unexpected_resource_kind opened.kind);
                   let opened_identity =
                     { dev = opened.dev; ino = opened.ino }
                   in
                   if
                     not
                       (Int64.equal opened_identity.dev created_identity.dev
                        && Int64.equal opened_identity.ino created_identity.ino)
                   then
                     raise_failure
                       Acquire_staging_directory
                       Resource_identity_changed);
                 (match !staging_directory_file with
                  | None ->
                    raise_failure
                      Apply_staging_directory_permissions
                      Resource_identity_unavailable
                  | Some directory_file ->
                    set_open_directory_permissions
                      ~before_stage
                      directory_file);
                 verify_path_identity
                   ~before_stage
                   ~stage:Verify_staging_directory_identity
                   ~expected_kind:`Directory
                   path
                   staging_directory_identity;
                 `Created)
           in
           Eio.Fiber.check ();
           match result with
           | `Created -> ()
           | `Collision -> create_fresh ()
         in
         create_fresh ()
       in
       let entry, file =
         match intent with
         | Atomic_replace ->
           create_owned_staging_directory ();
           run_stage ~before_stage Create_staging_entry (fun () ->
             match !staging_directory with
             | None ->
               raise_failure
                 Create_staging_entry
                 Resource_identity_unavailable
             | Some directory ->
               let entry =
                 Eio.Path.
                   ( (directory :> Eio.Fs.dir_ty Eio.Path.t)
                     / capability_staging_payload_leaf )
               in
               entry, Eio.Path.open_out ~sw ~create:(`Exclusive 0o600) entry)
         | Create_exclusive ->
           ( target
           , run_stage ~before_stage Create_target_entry (fun () ->
               Eio.Path.open_out ~sw ~create:(`Exclusive 0o600) target) )
       in
       payload_entry := Some entry;
       open_file := Some file;
       entry_created := true;
       if intent = Create_exclusive then parent_dirty := true;
       if intent = Create_exclusive
       then target_effect := Target_created_incomplete;
       identity := Some (identity_of_open_file ~before_stage file);
       write_open_file_payload ~before_stage file content;
       set_open_file_permissions ~before_stage file permissions;
       run_stage ~before_stage Sync_payload (fun () -> Eio.File.sync file);
       close_open_entry ~before_stage open_file;
       (match intent with
        | Atomic_replace ->
          Eio.Fiber.check ();
          Eio.Cancel.protect (fun () ->
            run_stage ~before_stage Publish_replace (fun () -> ());
            verify_entry_identity
              ~before_stage
              ~stage:Verify_entry_identity
              entry
              identity;
            let () =
              try Eio.Path.rename entry target with
              | Eio.Cancel.Cancelled _ as cancellation ->
                target_effect := Target_state_unknown;
                raise cancellation
              | exception_ ->
                let backtrace = Printexc.get_raw_backtrace () in
                target_effect := Target_state_unknown;
                raise
                  (Capability_write_failed
                     ( operation_failure Publish_replace exception_ backtrace
                     , [] ))
            in
            published := true;
            target_effect := Target_replaced;
            parent_dirty := true;
            (match !staging_directory_file with
             | None ->
               raise_failure
                 Sync_staging_directory
                 Resource_identity_unavailable
             | Some directory_file ->
               sync_open_directory_file
                 ~before_stage
                 ~stage:Sync_staging_directory
                 directory_file);
            (match !staging_path with
             | None ->
               raise_failure
                 Verify_staging_directory_identity
                 Resource_identity_unavailable
             | Some path ->
               verify_path_identity
                 ~before_stage
                 ~stage:Verify_staging_directory_identity
                 ~expected_kind:`Directory
                 path
                 staging_directory_identity;
               run_stage ~before_stage Remove_staging_directory (fun () ->
                 Eio.Path.rmdir path);
               staging_directory_removed := true;
               parent_dirty := true);
            sync_parent_capability ~before_stage ~stage:Sync_parent ~sw parent;
            parent_dirty := false;
            close_open_resource
              ~before_stage
              ~stage:Close_staging_directory
              staging_directory_file)
        | Create_exclusive ->
          verify_entry_identity
            ~before_stage
            ~stage:Verify_entry_identity
            entry
            identity;
          published := true;
          target_effect := Target_created;
          Eio.Cancel.protect (fun () ->
            sync_parent_capability ~before_stage ~stage:Sync_parent ~sw parent;
            parent_dirty := false));
       Eio.Fiber.check ();
       Ok ()
     with
     | Eio.Cancel.Cancelled reason as cancellation ->
       let backtrace = Printexc.get_raw_backtrace () in
       let reason, additional =
         match reason with
         | Parent_sync_cleanup_failed_on_cancellation (reason, failures) ->
           reason, failures
         | reason -> reason, []
       in
       let cleanup_failures = additional @ cleanup () in
       let target_effect =
         match intent with
         | Atomic_replace -> !target_effect
         | Create_exclusive -> !target_effect
       in
       (match target_effect, cleanup_failures with
        | Target_unchanged, [] ->
          Printexc.raise_with_backtrace cancellation backtrace
        | ( Target_unchanged
          | Target_created
          | Target_created_incomplete
          | Target_replaced
          | Target_state_unknown )
          , _ ->
         Printexc.raise_with_backtrace
           (Eio.Cancel.Cancelled
              (Capability_write_cancelled
                 ( reason
                 , { intent; target_effect; cleanup_failures } )))
           backtrace)
     | Capability_write_failed (failure, additional) ->
       error ~failure ~additional
     | exception_ ->
       let backtrace = Printexc.get_raw_backtrace () in
       error
         ~failure:(operation_failure create_stage exception_ backtrace)
         ~additional:[])
  with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Capability_write_failed (failure, cleanup_failures) ->
    Error
      { intent
      ; target_effect = Target_unchanged
      ; failure
      ; cleanup_failures
      }
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Error
      { intent
      ; target_effect = Target_unchanged
      ; failure = operation_failure Validate_leaf exception_ backtrace
      ; cleanup_failures = []
      }
;;

let publish_capability_file ~parent ~leaf ~intent ~permissions content =
  publish_capability_file_with
    ~before_stage:(fun _ -> ())
    ~parent
    ~leaf
    ~intent
    ~permissions
    content
;;

let sync_directory_capability_with ~before_stage directory =
  try
    let result =
      Eio.Switch.run @@ fun sw ->
      sync_parent_capability ~before_stage ~stage:Sync_parent ~sw directory;
      Ok ()
    in
    Eio.Fiber.check ();
    result
  with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Capability_write_failed (failure, cleanup_failures) ->
    Error { failure; cleanup_failures }
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Error
      { failure = operation_failure Sync_parent exception_ backtrace
      ; cleanup_failures = []
      }
;;

let sync_directory_capability directory =
  sync_directory_capability_with ~before_stage:(fun _ -> ()) directory
;;

module Capability_write_for_testing = struct
  let publish_capability_file
        ~before_stage
        ~parent
        ~leaf
        ~intent
        ~permissions
        content
    =
    publish_capability_file_with
      ~before_stage
      ~parent
      ~leaf
      ~intent
      ~permissions
      content
  ;;

  let sync_directory_capability = sync_directory_capability_with
end

let save_file_atomic
  ~(save_file : string -> string -> unit)
  (path : string)
  (content : string)
  : (unit, string) Result.t
  =
  let dir = Stdlib.Filename.dirname path in
  let tmp =
    Stdlib.Filename.temp_file ~temp_dir:dir atomic_tmp_prefix atomic_tmp_suffix
  in
  try
    save_file tmp content;
    fsync_path tmp;
    Stdlib.Sys.rename tmp path;
    (try fsync_path dir with
     | Unix.Unix_error _ -> ());
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e ->
    (try Stdlib.Sys.remove tmp with
     | Sys_error _ -> ());
    raise e
  | exn ->
    (try Stdlib.Sys.remove tmp with
     | Sys_error _ -> ());
    Error (Printf.sprintf "save_file_atomic %s: %s" path (Printexc.to_string exn))
;;

let has_atomic_temp_shape ~prefix name =
  let n = String.length name in
  let p = String.length prefix in
  let s = String.length atomic_tmp_suffix in
  n >= p + s
  && String.starts_with name ~prefix
  && String.ends_with ~suffix:atomic_tmp_suffix name
;;

let is_atomic_orphan_name name =
  has_atomic_temp_shape ~prefix:atomic_tmp_prefix name
;;

type atomic_orphan_cleanup_scope =
  | Directory_only
  | Directory_and_immediate_subdirectories

type atomic_orphan_cleanup_operation =
  | Inspect_cleanup_root
  | Read_cleanup_directory
  | Inspect_orphan
  | Create_recovery_directory
  | Sync_recovery_parent
  | Link_preserved_orphan
  | Verify_preserved_orphan
  | Sync_preserved_orphan
  | Sync_recovery_directory
  | Delete_empty_orphan
  | Delete_preserved_source
  | Sync_source_directory
  | Close_cleanup_descriptor

type atomic_orphan_cleanup_cause =
  | Unix_failure of Unix.error * string * string
  | Sys_failure of string
  | Unexpected_file_kind of Unix.file_kind
  | Outside_ownership_root of { ownership_root : string }
  | Identity_changed
  | Other_failure of exn

type atomic_orphan_cleanup_failure =
  { operation : atomic_orphan_cleanup_operation
  ; path : string
  ; cause : atomic_orphan_cleanup_cause
  }

type atomic_orphan_cleanup_report =
  { inspected : int
  ; deleted : int
  ; preserved : int
  ; failures : atomic_orphan_cleanup_failure list
  }

let atomic_orphan_cleanup_operation_to_string = function
  | Inspect_cleanup_root -> "inspect_cleanup_root"
  | Read_cleanup_directory -> "read_cleanup_directory"
  | Inspect_orphan -> "inspect_orphan"
  | Create_recovery_directory -> "create_recovery_directory"
  | Sync_recovery_parent -> "sync_recovery_parent"
  | Link_preserved_orphan -> "link_preserved_orphan"
  | Verify_preserved_orphan -> "verify_preserved_orphan"
  | Sync_preserved_orphan -> "sync_preserved_orphan"
  | Sync_recovery_directory -> "sync_recovery_directory"
  | Delete_empty_orphan -> "delete_empty_orphan"
  | Delete_preserved_source -> "delete_preserved_source"
  | Sync_source_directory -> "sync_source_directory"
  | Close_cleanup_descriptor -> "close_cleanup_descriptor"
;;

let file_kind_to_string = function
  | Unix.S_REG -> "regular_file"
  | Unix.S_DIR -> "directory"
  | Unix.S_CHR -> "character_device"
  | Unix.S_BLK -> "block_device"
  | Unix.S_LNK -> "symbolic_link"
  | Unix.S_FIFO -> "fifo"
  | Unix.S_SOCK -> "socket"
;;

let atomic_orphan_cleanup_cause_to_string = function
  | Unix_failure (error, fn, arg) ->
    Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message error)
  | Sys_failure detail -> detail
  | Unexpected_file_kind kind ->
    Printf.sprintf "unexpected file kind: %s" (file_kind_to_string kind)
  | Outside_ownership_root { ownership_root } ->
    Printf.sprintf "path is outside ownership root: %s" ownership_root
  | Identity_changed -> "filesystem identity changed during cleanup"
  | Other_failure exn -> Printexc.to_string exn
;;

let atomic_orphan_cleanup_failure_to_string failure =
  Printf.sprintf
    "operation=%s path=%s reason=%s"
    (atomic_orphan_cleanup_operation_to_string failure.operation)
    failure.path
    (atomic_orphan_cleanup_cause_to_string failure.cause)
;;

let cleanup_cause_of_exn = function
  | Unix.Unix_error (error, fn, arg) -> Unix_failure (error, fn, arg)
  | Sys_error detail -> Sys_failure detail
  | exn -> Other_failure exn
;;

let same_inode left right =
  left.Unix.st_dev = right.Unix.st_dev && left.Unix.st_ino = right.Unix.st_ino
;;

let cleanup_atomic_orphans ~ownership_root ~(base_path : string) ~scope () =
  let recovered_name = ".recovered" in
  let empty_report = { inspected = 0; deleted = 0; preserved = 0; failures = [] } in
  let add_failure report ~operation ~path cause =
    { report with failures = { operation; path; cause } :: report.failures }
  in
  let record_exn report ~operation ~path exn =
    match exn with
    | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
    | exn -> add_failure report ~operation ~path (cleanup_cause_of_exn exn)
  in
  let lstat report ~operation path =
    try Some (Unix.lstat path), report with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> None, report
    | exn -> None, record_exn report ~operation ~path exn
  in
  let identity_is_current report ~operation ~path ~expected ~kind =
    match lstat report ~operation path with
    | Some actual, report
      when actual.Unix.st_kind = kind && same_inode expected actual ->
      true, report
    | Some actual, report when actual.Unix.st_kind <> kind ->
      ( false
      , add_failure
          report
          ~operation
          ~path
          (Unexpected_file_kind actual.Unix.st_kind) )
    | Some _, report ->
      false, add_failure report ~operation ~path Identity_changed
    | None, report ->
      false, add_failure report ~operation ~path Identity_changed
  in
  let inspect_owned_chain report =
    try
      match Owned_directory_chain.inspect ~ownership_root base_path with
      | Ok Owned_directory_chain.Owned_directory_missing -> None, report
      | Ok (Owned_directory_chain.Owned_directory stat) -> Some stat, report
      | Error (Owned_directory_chain.Owned_path_outside_root _) ->
        ( None
        , add_failure
            report
            ~operation:Inspect_cleanup_root
            ~path:base_path
            (Outside_ownership_root { ownership_root }) )
      | Error (Owned_directory_chain.Owned_path_non_directory { path; kind }) ->
        ( None
        , add_failure
            report
            ~operation:Inspect_cleanup_root
            ~path
            (Unexpected_file_kind kind) )
    with
    | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
    | exn ->
      None, record_exn report ~operation:Inspect_cleanup_root ~path:base_path exn
  in
  let close_descriptor report path fd =
    try Unix.close fd; report with
    | exn -> record_exn report ~operation:Close_cleanup_descriptor ~path exn
  in
  let sync_verified_path report ~operation ~path ~expected ~kind =
    let opened =
      try
        Ok
          (Unix.openfile
             path
             [ Unix.O_RDONLY; Unix.O_CLOEXEC; Unix.O_NONBLOCK ]
             0)
      with
      | exn -> Error exn
    in
    match opened with
    | Error exn -> None, record_exn report ~operation ~path exn
    | Ok fd ->
      let finish report result =
        let report = close_descriptor report path fd in
        result, report
      in
      (try
         let actual = Unix.fstat fd in
         if actual.Unix.st_kind <> kind || not (same_inode expected actual)
         then finish report None
                |> fun (_, report) ->
                None, add_failure report ~operation ~path Identity_changed
         else (
           Unix.fsync fd;
           finish report (Some ()))
       with
       | exn ->
         let report = record_exn report ~operation ~path exn in
         finish report None)
  in
  let ensure_child_directory report ~parent ~parent_stat name =
    let path = Filename.concat parent name in
    match lstat report ~operation:Create_recovery_directory path with
    | Some stat, report when stat.Unix.st_kind = Unix.S_DIR ->
      Some (path, stat), report
    | Some stat, report ->
      ( None
      , add_failure
          report
          ~operation:Create_recovery_directory
          ~path
          (Unexpected_file_kind stat.Unix.st_kind) )
    | None, report ->
      (try
         Unix.mkdir path 0o700;
         let synced_parent, report =
           sync_verified_path
             report
             ~operation:Sync_recovery_parent
             ~path:parent
             ~expected:parent_stat
             ~kind:Unix.S_DIR
         in
         (match synced_parent with
          | None -> None, report
          | Some () ->
            (match lstat report ~operation:Create_recovery_directory path with
             | Some stat, report when stat.Unix.st_kind = Unix.S_DIR ->
               Some (path, stat), report
             | Some stat, report ->
               ( None
               , add_failure
                   report
                   ~operation:Create_recovery_directory
                   ~path
                   (Unexpected_file_kind stat.Unix.st_kind) )
             | None, report ->
               ( None
               , add_failure
                   report
                   ~operation:Create_recovery_directory
                   ~path
                   Identity_changed )))
       with
       | Unix.Unix_error (Unix.EEXIST, _, _) ->
         (match lstat report ~operation:Create_recovery_directory path with
          | Some stat, report when stat.Unix.st_kind = Unix.S_DIR ->
            Some (path, stat), report
          | Some stat, report ->
            ( None
            , add_failure
                report
                ~operation:Create_recovery_directory
                ~path
                (Unexpected_file_kind stat.Unix.st_kind) )
          | None, report ->
            ( None
            , add_failure
                report
                ~operation:Create_recovery_directory
                ~path
                Identity_changed ))
       | exn ->
         None, record_exn report ~operation:Create_recovery_directory ~path exn)
  in
  let ensure_recovery_directory report ~base_stat source =
    match
      ensure_child_directory
        report
        ~parent:base_path
        ~parent_stat:base_stat
        recovered_name
    with
    | None, report -> None, report
    | Some (recovered, recovered_stat), report ->
      let first =
        match source with
        | `Root -> "root"
        | `Child _ -> "children"
      in
      (match
         ensure_child_directory
           report
           ~parent:recovered
           ~parent_stat:recovered_stat
           first
       with
       | None, report -> None, report
       | Some (destination, destination_stat), report ->
         (match source with
          | `Root -> Some (destination, destination_stat), report
          | `Child child ->
            ensure_child_directory
              report
              ~parent:destination
              ~parent_stat:destination_stat
              child))
  in
  let find_or_create_preserved_link
        report
        ~source_path
        ~source_stat
        ~source_dir
        ~source_dir_stat
        ~destination
        ~destination_stat
        name
    =
    let rec loop report collision =
      let candidate_name =
        if collision = 0 then name else Printf.sprintf "%s.%d" name collision
      in
      let candidate = Filename.concat destination candidate_name in
      let source_current, report =
        identity_is_current
          report
          ~operation:Verify_preserved_orphan
          ~path:source_path
          ~expected:source_stat
          ~kind:Unix.S_REG
      in
      let source_dir_current, report =
        identity_is_current
          report
          ~operation:Verify_preserved_orphan
          ~path:source_dir
          ~expected:source_dir_stat
          ~kind:Unix.S_DIR
      in
      let destination_current, report =
        identity_is_current
          report
          ~operation:Verify_preserved_orphan
          ~path:destination
          ~expected:destination_stat
          ~kind:Unix.S_DIR
      in
      if not (source_current && source_dir_current && destination_current)
      then None, report
      else
        try
          Unix.link ~follow:false source_path candidate;
          Some candidate, report
        with
        | Unix.Unix_error (Unix.EEXIST, _, _) ->
          (match lstat report ~operation:Verify_preserved_orphan candidate with
           | Some stat, report
             when stat.Unix.st_kind = Unix.S_REG && same_inode source_stat stat ->
             Some candidate, report
           | _, report -> loop report (collision + 1))
        | exn ->
          ( None
          , record_exn report ~operation:Link_preserved_orphan ~path:candidate exn )
    in
    loop report 0
  in
  let preserve_nonempty report ~base_stat ~dir ~dir_stat ~source name source_stat =
    match ensure_recovery_directory report ~base_stat source with
    | None, report -> report
    | Some (destination, destination_stat), report ->
      let source_path = Filename.concat dir name in
      (match
         find_or_create_preserved_link
           report
           ~source_path
           ~source_stat
           ~source_dir:dir
           ~source_dir_stat:dir_stat
           ~destination
           ~destination_stat
           name
       with
       | None, report -> report
       | Some target, report ->
         let target_stat, report =
           lstat report ~operation:Verify_preserved_orphan target
         in
         (match target_stat with
          | Some target_stat
            when target_stat.Unix.st_kind = Unix.S_REG
                 && same_inode source_stat target_stat ->
            let synced_file, report =
              sync_verified_path
                report
                ~operation:Sync_preserved_orphan
                ~path:target
                ~expected:target_stat
                ~kind:Unix.S_REG
            in
            let synced_destination, report =
              sync_verified_path
                report
                ~operation:Sync_recovery_directory
                ~path:destination
                ~expected:destination_stat
                ~kind:Unix.S_DIR
            in
            (match synced_file, synced_destination with
             | Some (), Some () ->
               let source_current, report =
                 identity_is_current
                   report
                   ~operation:Delete_preserved_source
                   ~path:source_path
                   ~expected:source_stat
                   ~kind:Unix.S_REG
               in
               let source_dir_current, report =
                 identity_is_current
                   report
                   ~operation:Delete_preserved_source
                   ~path:dir
                   ~expected:dir_stat
                   ~kind:Unix.S_DIR
               in
               if not (source_current && source_dir_current)
               then report
               else
                 (try
                    Unix.unlink source_path;
                    let _, report =
                      sync_verified_path
                        report
                        ~operation:Sync_source_directory
                        ~path:dir
                        ~expected:dir_stat
                        ~kind:Unix.S_DIR
                    in
                    { report with preserved = report.preserved + 1 }
                  with
                  | exn ->
                    record_exn
                      report
                      ~operation:Delete_preserved_source
                      ~path:source_path
                      exn)
             | None, _ | _, None -> report)
          | Some target_stat when target_stat.Unix.st_kind <> Unix.S_REG ->
            add_failure
              report
              ~operation:Verify_preserved_orphan
              ~path:target
              (Unexpected_file_kind target_stat.Unix.st_kind)
          | Some _ ->
            add_failure
              report
              ~operation:Verify_preserved_orphan
              ~path:target
              Identity_changed
          | None ->
            add_failure
              report
              ~operation:Verify_preserved_orphan
              ~path:target
              Identity_changed))
  in
  let delete_empty report ~dir ~dir_stat ~source_stat path =
    let source_current, report =
      identity_is_current
        report
        ~operation:Delete_empty_orphan
        ~path
        ~expected:source_stat
        ~kind:Unix.S_REG
    in
    let source_dir_current, report =
      identity_is_current
        report
        ~operation:Delete_empty_orphan
        ~path:dir
        ~expected:dir_stat
        ~kind:Unix.S_DIR
    in
    if not (source_current && source_dir_current)
    then report
    else
      try
        Unix.unlink path;
        let _, report =
          sync_verified_path
            report
            ~operation:Sync_source_directory
            ~path:dir
            ~expected:dir_stat
            ~kind:Unix.S_DIR
        in
        { report with deleted = report.deleted + 1 }
      with
      | exn -> record_exn report ~operation:Delete_empty_orphan ~path exn
  in
  (* TEL-OK: this leaf returns every cleanup decision/failure in the typed
     [report]; the schema owner records that report to its metric namespace. *)
  let handle_orphan report ~base_stat ~source ~dir ~dir_stat name =
    let path = Filename.concat dir name in
    match lstat report ~operation:Inspect_orphan path with
    | None, report ->
      add_failure report ~operation:Inspect_orphan ~path Identity_changed
    | Some stat, report when stat.Unix.st_kind <> Unix.S_REG ->
      add_failure
        report
        ~operation:Inspect_orphan
        ~path
        (Unexpected_file_kind stat.Unix.st_kind)
    | Some stat, report when stat.Unix.st_size = 0 ->
      delete_empty report ~dir ~dir_stat ~source_stat:stat path
    | Some stat, report ->
      preserve_nonempty report ~base_stat ~dir ~dir_stat ~source name stat
  in
  let fold_directory report ~base_stat ~source ~dir ~dir_stat ~on_entry =
    let opened =
      try Ok (Unix.opendir dir) with
      | exn -> Error exn
    in
    match opened with
    | Error exn ->
      record_exn report ~operation:Read_cleanup_directory ~path:dir exn
    | Ok handle ->
      let close_after_exception exn =
        let backtrace = Printexc.get_raw_backtrace () in
        (try Unix.closedir handle with
         | close_exn ->
           Stdlib.Printf.eprintf
             "[atomic_write] close after cleanup exception failed path=%s primary=%s close=%s\n%!"
             dir
             (Printexc.to_string exn)
             (Printexc.to_string close_exn));
        Printexc.raise_with_backtrace exn backtrace
      in
      let rec loop report =
        match Unix.readdir handle with
        | name ->
          let report =
            if String.equal name "." || String.equal name ".."
            then report
            else on_entry report ~base_stat ~source ~dir ~dir_stat name
          in
          loop report
        | exception End_of_file -> report
        | exception exn ->
          record_exn report ~operation:Read_cleanup_directory ~path:dir exn
      in
      let report =
        try loop report with
        | exn -> close_after_exception exn
      in
      (try Unix.closedir handle; report with
       | exn ->
         record_exn report ~operation:Close_cleanup_descriptor ~path:dir exn)
  in
  let scan_orphans report ~base_stat ~source ~dir ~dir_stat =
    fold_directory
      report
      ~base_stat
      ~source
      ~dir
      ~dir_stat
      ~on_entry:(fun report ~base_stat ~source ~dir ~dir_stat name ->
        if is_atomic_orphan_name name
        then
          handle_orphan
            { report with inspected = report.inspected + 1 }
            ~base_stat
            ~source
            ~dir
            ~dir_stat
            name
        else report)
  in
  let result =
    match inspect_owned_chain empty_report with
    | None, report -> report
    | Some base_stat, report ->
      let report =
        scan_orphans
          report
          ~base_stat
          ~source:`Root
          ~dir:base_path
          ~dir_stat:base_stat
      in
      (match scope with
       | Directory_only -> report
       | Directory_and_immediate_subdirectories ->
         fold_directory
           report
           ~base_stat
           ~source:`Root
           ~dir:base_path
           ~dir_stat:base_stat
           ~on_entry:(fun report ~base_stat ~source:_ ~dir ~dir_stat:_ name ->
             if String.equal name recovered_name
             then report
             else (
               let child = Filename.concat dir name in
               match lstat report ~operation:Inspect_cleanup_root child with
               | Some child_stat, report
                 when child_stat.Unix.st_kind = Unix.S_DIR ->
                 scan_orphans
                   report
                   ~base_stat
                   ~source:(`Child name)
                   ~dir:child
                   ~dir_stat:child_stat
               | Some _, report
               | None, report -> report)))
  in
  { result with failures = List.rev result.failures }
;;
