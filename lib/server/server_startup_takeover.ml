type base_path_lease =
  { fd : Unix.file_descr
  ; path : string
  }

type base_path_lock_rejection =
  | Base_path_canonicalization_failed of
      { base_path : string
      ; reason : string
      }
  | Base_path_not_directory of
      { path : string
      ; kind : Unix.file_kind
      }
  | Run_directory_canonicalization_failed of
      { run_dir : string
      ; reason : string
      }
  | Run_directory_not_directory of
      { path : string
      ; kind : Unix.file_kind
      }
  | Run_directory_untrusted_owner of
      { path : string
      ; effective_uid : int
      ; observed_uid : int
      }
  | Run_directory_insecure_permissions of
      { path : string
      ; permissions : int
      }
  | Lease_directory_creation_failed of
      { path : string
      ; reason : string
      }
  | Lease_directory_not_directory of
      { path : string
      ; kind : Unix.file_kind
      }
  | Lease_directory_wrong_owner of
      { path : string
      ; expected_uid : int
      ; observed_uid : int
      }
  | Lease_directory_insecure_permissions of
      { path : string
      ; permissions : int
      }
  | Lease_directory_identity_changed of { path : string }
  | Runtime_directory_rejected of Fs_compat.owned_directory_chain_rejection
  | Runtime_directory_creation_failed of
      { path : string
      ; reason : string
      }
  | Lease_file_non_regular of
      { path : string
      ; kind : Unix.file_kind
      }
  | Lease_file_multiply_linked of
      { path : string
      ; links : int
      }
  | Lease_file_wrong_owner of
      { path : string
      ; expected_uid : int
      ; observed_uid : int
      }
  | Lease_identity_changed of { path : string }
  | Lease_io_failed of
      { operation : string
      ; path : string
      ; reason : string
      }

(* Only the process-local table establishes ownership identity. The recorded
   number is written after locking and may describe a previous owner or a
   different PID namespace; local process liveness cannot verify it. *)
type base_path_owner =
  | Owner_this_process of int
      (** This process already holds the lease. A second acquisition in the
          same process would take the same kernel lock, which is why the
          in-process table is consulted first. *)
  | Owner_recorded of int
      (** A number recorded in the lease, with no verified PID namespace or
          current-holder identity. It may be stale or identify another process. *)
  | Owner_unnamed
      (** The lease file carried no readable number. *)

type base_path_acquire_result =
  | Base_path_acquired of base_path_lease
  | Base_path_already_owned of { owner : base_path_owner; lock_path : string }
  | Base_path_rejected of base_path_lock_rejection

let base_path_lock_rejection_to_string = function
  | Base_path_canonicalization_failed { base_path; reason } ->
    Printf.sprintf "BasePath canonicalization failed path=%s error=%s" base_path reason
  | Base_path_not_directory { path; kind } ->
    Printf.sprintf
      "BasePath is not a directory path=%s kind=%s"
      path
      (Fs_compat.file_kind_to_string kind)
  | Run_directory_canonicalization_failed { run_dir; reason } ->
    Printf.sprintf
      "host run directory canonicalization failed path=%s error=%s"
      run_dir
      reason
  | Run_directory_not_directory { path; kind } ->
    Printf.sprintf
      "host run directory is not a directory path=%s kind=%s"
      path
      (Fs_compat.file_kind_to_string kind)
  | Run_directory_untrusted_owner { path; effective_uid; observed_uid } ->
    Printf.sprintf
      "host run directory owner is outside the process/system trust boundary path=%s effective_uid=%d observed_uid=%d"
      path
      effective_uid
      observed_uid
  | Run_directory_insecure_permissions { path; permissions } ->
    Printf.sprintf
      "host run directory is writable by another UID without sticky-bit protection path=%s permissions=%04o"
      path
      permissions
  | Lease_directory_creation_failed { path; reason } ->
    Printf.sprintf
      "private BasePath lease directory creation failed path=%s error=%s"
      path
      reason
  | Lease_directory_not_directory { path; kind } ->
    Printf.sprintf
      "private BasePath lease path is not a directory path=%s kind=%s"
      path
      (Fs_compat.file_kind_to_string kind)
  | Lease_directory_wrong_owner { path; expected_uid; observed_uid } ->
    Printf.sprintf
      "private BasePath lease directory owner mismatch path=%s expected_uid=%d observed_uid=%d"
      path
      expected_uid
      observed_uid
  | Lease_directory_insecure_permissions { path; permissions } ->
    Printf.sprintf
      "private BasePath lease directory permissions are not 0700 path=%s permissions=%04o"
      path
      permissions
  | Lease_directory_identity_changed { path } ->
    Printf.sprintf
      "private BasePath lease directory identity changed before ownership commit path=%s"
      path
  | Runtime_directory_rejected rejection ->
    Fs_compat.owned_directory_chain_rejection_to_string rejection
  | Runtime_directory_creation_failed { path; reason } ->
    Printf.sprintf "runtime directory creation failed path=%s error=%s" path reason
  | Lease_file_non_regular { path; kind } ->
    Printf.sprintf
      "BasePath lease is not a regular file path=%s kind=%s"
      path
      (Fs_compat.file_kind_to_string kind)
  | Lease_file_multiply_linked { path; links } ->
    Printf.sprintf
      "BasePath lease has multiple hard links path=%s links=%d"
      path
      links
  | Lease_file_wrong_owner { path; expected_uid; observed_uid } ->
    Printf.sprintf
      "BasePath lease owner mismatch path=%s expected_uid=%d observed_uid=%d"
      path
      expected_uid
      observed_uid
  | Lease_identity_changed { path } ->
    Printf.sprintf "BasePath lease identity changed before ownership commit path=%s" path
  | Lease_io_failed { operation; path; reason } ->
    Printf.sprintf
      "BasePath lease I/O failed operation=%s path=%s error=%s"
      operation
      path
      reason
;;

let base_path_lease_mu = Mutex.create ()

type retained_base_path_fd =
  | Active_lease of base_path_lease
  | Failed_close of base_path_lease * base_path_lock_rejection

let base_path_leases : (string, retained_base_path_fd) Hashtbl.t =
  Hashtbl.create 2
;;

let close_acquisition_fd ~operation ~path ~context fd =
  try
    Unix.close fd;
    Ok ()
  with
  | exn -> (* cancel-guard-ok: Unix.close performs no Eio operation. *)
    let rejection =
      Lease_io_failed
        { operation
        ; path
        ; reason =
            Printf.sprintf
              "%s; close failed: %s"
              context
              (Printexc.to_string exn)
        }
    in
    (* [acquire_base_path_lock_with] holds [base_path_lease_mu]. A failed
       close leaves descriptor and kernel-lock ownership ambiguous, so retain
       a process-local fence and return an explicit typed rejection. *)
    Hashtbl.replace
      base_path_leases
      path
      (Failed_close ({ fd; path }, rejection));
    Error rejection
;;

let private_lease_directory_permissions = 0o700
let private_lease_directory_prefix = "masc-base-path-leases-v1"

let base_path_lease_directory ~run_dir ~owner_uid =
  Filename.concat
    run_dir
    (Printf.sprintf "%s-%d" private_lease_directory_prefix owner_uid)
;;

(* The lease used to be named by the digest of the canonical BasePath
   string. macOS answers [Unix.realpath] with two different strings for one
   directory (/private/tmp/X and /System/Volumes/Data/private/tmp/X), so two
   servers could hold two leases for the same directory. The lease is now
   named by the digest of the directory's own (st_dev, st_ino) identity, so
   one directory has exactly one lease name on every supported platform. *)
let base_path_lock_digest_of_stats (stat : Unix.stats) =
  Printf.sprintf "masc-base-path-lease:%d:%d" stat.st_dev stat.st_ino
  |> Agent_core_sha256.digest_string |> Agent_core_sha256.to_hex
;;

let base_path_owner_pid = function
  | Owner_this_process pid | Owner_recorded pid ->
    Some pid
  | Owner_unnamed -> None
;;

(* A shared lease can be written in another PID namespace. Local kill(pid, 0)
   cannot establish anything about the recorded process or the lock holder. *)
let base_path_owner_of_recorded = function
  | None -> Owner_unnamed
  | Some pid -> Owner_recorded pid
;;

let base_path_contention_message ~base_path ~lock_path owner =
  let detail =
    match owner with
    | Owner_this_process pid ->
      Printf.sprintf "This process (PID %d) already owns the lease" pid
    | Owner_recorded pid ->
      Printf.sprintf
        "The lease records PID %d; its namespace and current holder are unverified"
        pid
    | Owner_unnamed -> "The lease has no readable recorded PID"
  in
  Printf.sprintf
    "Base path %s is locked. %s. Lock file: %s. When the owner is this \
     workspace's server on this host, `masc restart` asks it to stop \
     gracefully and starts this build in its place. Otherwise inspect the \
     services or containers configured to use this base path on the owning \
     host and stop the confirmed owner there, or choose a different \
     --base-path. Do not signal the recorded PID or delete the lock file to \
     bypass ownership. If lsof is installed on the owning host, optional \
     open-file evidence: lsof %s (open files alone do not prove lock \
     ownership)."
    base_path detail (Filename.quote lock_path) (Filename.quote lock_path)
;;

let write_all fd content =
  let rec loop offset =
    if offset < String.length content
    then
      let written =
        Unix.write_substring fd content offset (String.length content - offset)
      in
      if written = 0 then raise End_of_file else loop (offset + written)
  in
  loop 0
;;

let release_base_path_lease lease =
  Mutex.protect base_path_lease_mu (fun () ->
    let owns_table_entry =
      match Hashtbl.find_opt base_path_leases lease.path with
      | Some (Active_lease current) -> current == lease
      | Some (Failed_close _) -> false
      | None -> false
    in
    if not owns_table_entry
    then
      (* File-descriptor integers may be reused immediately after close. Never
         touch an fd from a stale/double-released abstract handle: it may now
         designate an unrelated resource or a newer lease. *)
      Log.Server.error
        "BasePath lease release ignored because the handle is not the active owner: path=%s"
        lease.path
    else (
      (try
         let (_ : int) = Unix.lseek lease.fd 0 Unix.SEEK_SET in
         Unix.lockf lease.fd Unix.F_ULOCK 0
       with
       | Unix.Unix_error (error, syscall, argument) ->
         Log.Server.error
           "BasePath lease unlock failed: path=%s error=%s syscall=%s argument=%s"
           lease.path
           (Unix.error_message error)
           syscall
           argument);
      let closed =
        try
          Unix.close lease.fd;
          true
        with
        | Unix.Unix_error (error, syscall, argument) ->
          Log.Server.error
            "BasePath lease close failed: path=%s error=%s syscall=%s argument=%s"
            lease.path
            (Unix.error_message error)
            syscall
            argument;
          false
      in
      (* A failed close leaves descriptor ownership ambiguous. Retain the
         process-local fence in that case; admitting an alias after a failed
         release would be worse than an explicit fail-closed leak. *)
      if closed then Hashtbl.remove base_path_leases lease.path))
;;

let prepare_base_path_lease_exec_handoff lease =
  Mutex.protect base_path_lease_mu (fun () ->
    match Hashtbl.find_opt base_path_leases lease.path with
    | Some (Active_lease current) when current == lease ->
      (try
         Unix.clear_close_on_exec lease.fd;
         Ok ()
       with
       | exn -> (* cancel-guard-ok: Unix.clear_close_on_exec performs no Eio operation. *)
         Error
           (Lease_io_failed
              { operation = "prepare_exec_handoff"
              ; path = lease.path
              ; reason = Printexc.to_string exn
              }))
    | Some (Active_lease _) | Some (Failed_close _) | None ->
      Error
        (Lease_io_failed
           { operation = "prepare_exec_handoff"
           ; path = lease.path
           ; reason = "lease handle is not the active process owner"
           }))
;;

type prepared_base_path_lock =
  { canonical_base_path : string
  ; base_path_stat : Unix.stats
  ; run_directory : string
  ; run_directory_stat : Unix.stats
  ; lease_directory : string
  ; lease_directory_stat : Unix.stats
  ; runtime_directory : string
  ; path : string
  ; owner_uid : int
  }

let same_file_identity (left : Unix.stats) (right : Unix.stats) =
  left.st_dev = right.st_dev && left.st_ino = right.st_ino
;;

let permission_bits (stat : Unix.stats) = stat.st_perm land 0o7777

let validate_run_directory_boundary ~path ~owner_uid (stat : Unix.stats) =
  let permissions = permission_bits stat in
  (* Sticky mode protects an entry from peer UIDs, but the parent owner keeps
     removal authority. Limit that authority to the system or effective-UID
     host principal before relying on the sticky bit. *)
  let owner_is_trusted = stat.st_uid = owner_uid || stat.st_uid = 0 in
  if not owner_is_trusted
  then
    Error
      (Run_directory_untrusted_owner
         { path; effective_uid = owner_uid; observed_uid = stat.st_uid })
  else if permissions land 0o022 <> 0 && permissions land 0o1000 = 0
  then Error (Run_directory_insecure_permissions { path; permissions })
  else Ok ()
;;

type lease_directory_observation =
  | Lease_directory_missing
  | Lease_directory_ready of Unix.stats

let inspect_lease_directory ~path ~owner_uid =
  match Unix.lstat path with
  | stat when stat.Unix.st_kind <> Unix.S_DIR ->
    Error (Lease_directory_not_directory { path; kind = stat.st_kind })
  | stat when stat.st_uid <> owner_uid ->
    Error
      (Lease_directory_wrong_owner
         { path; expected_uid = owner_uid; observed_uid = stat.st_uid })
  | stat when permission_bits stat <> private_lease_directory_permissions ->
    Error
      (Lease_directory_insecure_permissions
         { path; permissions = permission_bits stat })
  | stat -> Ok (Lease_directory_ready stat)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Lease_directory_missing
  | exception Unix.Unix_error (error, syscall, argument) ->
    Error
      (Lease_io_failed
         { operation = "inspect_private_lease_directory"
         ; path
         ; reason =
             Printf.sprintf
               "%s syscall=%s argument=%s"
               (Unix.error_message error)
               syscall
               argument
         })
;;

let establish_lease_directory ~path ~owner_uid =
  let inspect () = inspect_lease_directory ~path ~owner_uid in
  match inspect () with
  | Error _ as error -> error
  | Ok (Lease_directory_ready stat) -> Ok stat
  | Ok Lease_directory_missing ->
    (match
       try
         Unix.mkdir path private_lease_directory_permissions;
         Ok ()
       with
       | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
       | Unix.Unix_error (error, syscall, argument) ->
         Error
           (Lease_directory_creation_failed
              { path
              ; reason =
                  Printf.sprintf
                    "%s syscall=%s argument=%s"
                    (Unix.error_message error)
                    syscall
                    argument
              })
     with
     | Error _ as error -> error
     | Ok () ->
       (match inspect () with
        | Error _ as error -> error
        | Ok Lease_directory_missing ->
          Error
            (Lease_directory_creation_failed
               { path; reason = "directory remained missing after mkdir" })
        | Ok (Lease_directory_ready stat) -> Ok stat))
;;

let verify_directory_identity ~path ~expected =
  match Unix.lstat path with
  | current
    when current.Unix.st_kind = Unix.S_DIR
         && same_file_identity expected current -> Ok ()
  | _ -> Error (Lease_identity_changed { path })
  | exception Unix.Unix_error (error, syscall, argument) ->
    Error
      (Lease_io_failed
         { operation = "verify_directory_identity"
         ; path
         ; reason =
             Printf.sprintf
               "%s syscall=%s argument=%s"
               (Unix.error_message error)
               syscall
               argument
         })
;;

let verify_run_directory_identity ~path ~owner_uid ~expected =
  match Unix.lstat path with
  | current
    when current.Unix.st_kind = Unix.S_DIR
         && same_file_identity expected current ->
    validate_run_directory_boundary ~path ~owner_uid current
  | _ -> Error (Lease_identity_changed { path })
  | exception Unix.Unix_error (error, syscall, argument) ->
    Error
      (Lease_io_failed
         { operation = "verify_run_directory_identity"
         ; path
         ; reason =
             Printf.sprintf
               "%s syscall=%s argument=%s"
               (Unix.error_message error)
               syscall
               argument
         })
;;

let verify_lease_directory_identity ~path ~owner_uid ~expected =
  match inspect_lease_directory ~path ~owner_uid with
  | Error _ as error -> error
  | Ok Lease_directory_missing -> Error (Lease_directory_identity_changed { path })
  | Ok (Lease_directory_ready current) ->
    if same_file_identity expected current
    then Ok ()
    else Error (Lease_directory_identity_changed { path })
;;

let inspect_runtime_directory ~base_path runtime_directory =
  try
    match
      Fs_compat.inspect_owned_directory_chain
        ~ownership_root:base_path
        runtime_directory
    with
    | Ok (Fs_compat.Owned_directory stat) -> Ok (`Ready stat)
    | Ok Fs_compat.Owned_directory_missing -> Ok `Missing
    | Error rejection -> Error (Runtime_directory_rejected rejection)
  with
  | exn -> (* cancel-guard-ok: Fs_compat directory inspection is Unix calls, no Eio operation *)
    Error
      (Lease_io_failed
         { operation = "inspect_runtime_directory"
         ; path = runtime_directory
         ; reason = Printexc.to_string exn
         })
;;

let prepare_base_path_lock ~run_dir base_path =
  let open Result.Syntax in
  let* canonical_base_path =
    try Ok (Unix.realpath base_path) with
    | exn -> (* cancel-guard-ok: Unix.realpath performs no Eio operation. *)
      Error
        (Base_path_canonicalization_failed
           { base_path; reason = Printexc.to_string exn })
  in
  let* base_path_stat =
    match Unix.lstat canonical_base_path with
    | stat when stat.Unix.st_kind = Unix.S_DIR -> Ok stat
    | stat ->
      Error
        (Base_path_not_directory
           { path = canonical_base_path; kind = stat.st_kind })
    | exception exn -> (* cancel-guard-ok: Unix.lstat performs no Eio operation. *)
      Error
        (Lease_io_failed
           { operation = "lstat_base_path"
           ; path = canonical_base_path
           ; reason = Printexc.to_string exn
           })
  in
  let* run_directory =
    try Ok (Unix.realpath run_dir) with
    | exn -> (* cancel-guard-ok: Unix.realpath performs no Eio operation. *)
      Error
        (Run_directory_canonicalization_failed
           { run_dir; reason = Printexc.to_string exn })
  in
  let* run_directory_stat =
    match Unix.lstat run_directory with
    | stat when stat.Unix.st_kind = Unix.S_DIR -> Ok stat
    | stat ->
      Error
        (Run_directory_not_directory
           { path = run_directory; kind = stat.st_kind })
    | exception exn -> (* cancel-guard-ok: Unix.lstat performs no Eio operation. *)
      Error
        (Lease_io_failed
           { operation = "lstat_run_directory"
           ; path = run_directory
           ; reason = Printexc.to_string exn
           })
  in
  let owner_uid = Unix.geteuid () in
  let* () =
    validate_run_directory_boundary
      ~path:run_directory
      ~owner_uid
      run_directory_stat
  in
  let lease_directory =
    base_path_lease_directory ~run_dir:run_directory ~owner_uid
  in
  let* lease_directory_stat =
    establish_lease_directory ~path:lease_directory ~owner_uid
  in
  let* () =
    verify_run_directory_identity
      ~path:run_directory
      ~owner_uid
      ~expected:run_directory_stat
  in
  let* () =
    verify_lease_directory_identity
      ~path:lease_directory
      ~owner_uid
      ~expected:lease_directory_stat
  in
  Ok
    { canonical_base_path
    ; base_path_stat
    ; run_directory
    ; run_directory_stat
    ; lease_directory
    ; lease_directory_stat
    ; runtime_directory =
        Filename.concat canonical_base_path Common.masc_dirname
    ; path =
        Filename.concat
          lease_directory
          (Printf.sprintf
             "masc-base-path-owner-v2-%s.lease"
             (base_path_lock_digest_of_stats base_path_stat))
    ; owner_uid
    }
;;

let establish_runtime_directory prepared =
  let inspect () =
    inspect_runtime_directory
      ~base_path:prepared.canonical_base_path
      prepared.runtime_directory
  in
  match inspect () with
  | Error _ as error -> error
  | Ok (`Ready stat) -> Ok stat
  | Ok `Missing ->
    (match
       try
         Unix.mkdir prepared.runtime_directory 0o755;
         Ok ()
       with
       | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
       | exn -> (* cancel-guard-ok: Unix.mkdir performs no Eio operation *)
         Error
           (Runtime_directory_creation_failed
              { path = prepared.runtime_directory; reason = Printexc.to_string exn })
     with
     | Error _ as error -> error
     | Ok () ->
       (match inspect () with
        | Error _ as error -> error
        | Ok `Missing ->
          Error
            (Runtime_directory_creation_failed
               { path = prepared.runtime_directory
               ; reason = "directory remained missing after mkdir"
               })
        | Ok (`Ready stat) -> Ok stat))
;;

type lease_path_observation =
  | Lease_path_missing
  | Lease_path_regular of Unix.stats
  | Lease_path_other of Unix.file_kind

let observe_lease_path path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind = Unix.S_REG
    then Ok (Lease_path_regular stat)
    else Ok (Lease_path_other stat.st_kind)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Lease_path_missing
  | exn -> (* cancel-guard-ok: Unix.lstat performs no Eio operation *)
    Error
      (Lease_io_failed
         { operation = "lstat_lease_file"
         ; path
         ; reason = Printexc.to_string exn
         })
;;

let verify_open_lease_file prepared fd expected_file_stat =
  let reject rejection =
    match
      close_acquisition_fd
        ~operation:"close_rejected_lease_file"
        ~path:prepared.path
        ~context:(base_path_lock_rejection_to_string rejection)
        fd
    with
    | Ok () -> Error rejection
    | Error close_rejection -> Error close_rejection
  in
  try
    let descriptor_stat = Unix.fstat fd in
    if descriptor_stat.Unix.st_kind <> Unix.S_REG
    then reject (Lease_file_non_regular { path = prepared.path; kind = descriptor_stat.st_kind })
    else if descriptor_stat.st_nlink > 1
    then
      reject
        (Lease_file_multiply_linked
           { path = prepared.path; links = descriptor_stat.st_nlink })
    (* st_nlink = 0 is not "multiply linked": the descriptor is the only
       remaining reference, so the name was replaced after the open. The
       lstat below reports what the path became instead. *)
    else if descriptor_stat.st_uid <> prepared.owner_uid
    then
      reject
        (Lease_file_wrong_owner
           { path = prepared.path
           ; expected_uid = prepared.owner_uid
           ; observed_uid = descriptor_stat.st_uid
           })
    else
      match
        verify_run_directory_identity
          ~path:prepared.run_directory
          ~owner_uid:prepared.owner_uid
          ~expected:prepared.run_directory_stat
      with
      | Error rejection -> reject rejection
      | Ok () ->
        (match
           verify_lease_directory_identity
             ~path:prepared.lease_directory
             ~owner_uid:prepared.owner_uid
             ~expected:prepared.lease_directory_stat
         with
         | Error rejection -> reject rejection
         | Ok () ->
         (match Unix.lstat prepared.path with
         | path_stat when path_stat.Unix.st_kind <> Unix.S_REG ->
           reject
             (Lease_file_non_regular
                { path = prepared.path; kind = path_stat.st_kind })
         | path_stat when path_stat.st_nlink > 1 ->
           reject
             (Lease_file_multiply_linked
                { path = prepared.path; links = path_stat.st_nlink })
         | path_stat when path_stat.st_uid <> prepared.owner_uid ->
           reject
             (Lease_file_wrong_owner
                { path = prepared.path
                ; expected_uid = prepared.owner_uid
                ; observed_uid = path_stat.st_uid
                })
         | path_stat
           when not (same_file_identity descriptor_stat path_stat)
                ||
                (match expected_file_stat with
                 | None -> false
                 | Some expected -> not (same_file_identity expected path_stat)) ->
           reject (Lease_identity_changed { path = prepared.path })
           | _ ->
             (match
                verify_lease_directory_identity
                  ~path:prepared.lease_directory
                  ~owner_uid:prepared.owner_uid
                  ~expected:prepared.lease_directory_stat
              with
              | Error rejection -> reject rejection
              | Ok () ->
                (match
                   verify_run_directory_identity
                     ~path:prepared.run_directory
                     ~owner_uid:prepared.owner_uid
                     ~expected:prepared.run_directory_stat
                 with
                 | Error rejection -> reject rejection
                 | Ok () ->
                   (match
                      verify_directory_identity
                        ~path:prepared.canonical_base_path
                        ~expected:prepared.base_path_stat
                    with
                    | Error rejection -> reject rejection
                    | Ok () -> Ok fd)))))
  with
  | exn ->
    reject
      (Lease_io_failed
         { operation = "verify_lease_identity"
         ; path = prepared.path
         ; reason = Printexc.to_string exn
         })
;;

let open_existing_lease_file prepared expected_file_stat =
  if expected_file_stat.Unix.st_uid <> prepared.owner_uid
  then
    Error
      (Lease_file_wrong_owner
         { path = prepared.path
         ; expected_uid = prepared.owner_uid
         ; observed_uid = expected_file_stat.st_uid
         })
  else
    try
      let fd = Unix.openfile prepared.path [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
      verify_open_lease_file prepared fd (Some expected_file_stat)
    with
    | exn -> (* cancel-guard-ok: Unix.openfile, and the Unix.fstat inside verify_open_lease_file, perform no Eio operation. *)
      Error
        (Lease_io_failed
           { operation = "open_existing_lease_file"
           ; path = prepared.path
           ; reason = Printexc.to_string exn
           })
;;

let open_lease_file prepared =
  match
    verify_run_directory_identity
      ~path:prepared.run_directory
      ~owner_uid:prepared.owner_uid
      ~expected:prepared.run_directory_stat
  with
  | Error _ as error -> error
  | Ok () ->
    (match
       verify_lease_directory_identity
         ~path:prepared.lease_directory
         ~owner_uid:prepared.owner_uid
         ~expected:prepared.lease_directory_stat
     with
     | Error _ as error -> error
     | Ok () ->
       (match observe_lease_path prepared.path with
     | Error _ as error -> error
     | Ok (Lease_path_other kind) ->
       Error (Lease_file_non_regular { path = prepared.path; kind })
     | Ok (Lease_path_regular stat) -> open_existing_lease_file prepared stat
     | Ok Lease_path_missing ->
       (try
          let fd =
            Unix.openfile
              prepared.path
              [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
              0o600
          in
          verify_open_lease_file prepared fd None
        with
        | Unix.Unix_error (Unix.EEXIST, _, _) ->
          (match observe_lease_path prepared.path with
           | Ok (Lease_path_regular stat) -> open_existing_lease_file prepared stat
           | Ok (Lease_path_other kind) ->
             Error (Lease_file_non_regular { path = prepared.path; kind })
           | Ok Lease_path_missing ->
             Error (Lease_identity_changed { path = prepared.path })
           | Error _ as error -> error)
          | exn ->
            Error
              (Lease_io_failed
                 { operation = "create_lease_file"
                 ; path = prepared.path
                 ; reason = Printexc.to_string exn
                 }))))
;;

let parsed_pid_fd fd =
  let maximum_length = String.length (string_of_int max_int) + 1 in
  let payload = Bytes.create maximum_length in
  try
    let (_ : int) = Unix.lseek fd 0 Unix.SEEK_SET in
    let rec read offset =
      if offset = maximum_length
      then offset
      else
        let count = Unix.read fd payload offset (maximum_length - offset) in
        if count = 0 then offset else read (offset + count)
    in
    let length = read 0 in
    Bytes.sub_string payload 0 length |> String.trim |> int_of_string_opt
  with
  | exn -> (* cancel-guard-ok: Unix.lseek and Unix.read perform no Eio operation. *)
    Log.Server.error
      "BasePath lease owner read failed path_fd error=%s"
      (Printexc.to_string exn);
    None
;;

(* What acquisition does when another process holds the kernel lock. *)
type contention =
  | Refuse_when_owned
  | Wait_for_release of (base_path_owner -> unit)

let rec lockf_until_granted fd =
  try Unix.lockf fd Unix.F_LOCK 0 with
  | Unix.Unix_error (Unix.EINTR, _, _) -> lockf_until_granted fd
;;

(* [F_TLOCK] first even when waiting, so the caller hears who it waits for
   before the process blocks; [F_LOCK] then sleeps in the kernel until the
   owner's descriptor closes, which every exit does, normal or forced. *)
let lock_lease_file ~contention fd =
  match contention with
  | Refuse_when_owned -> Unix.lockf fd Unix.F_TLOCK 0
  | Wait_for_release on_wait ->
    (try Unix.lockf fd Unix.F_TLOCK 0 with
     | Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
       on_wait (base_path_owner_of_recorded (parsed_pid_fd fd));
       (* [parsed_pid_fd] moved the offset; lockf locks from the offset on,
          and every other holder locks from byte 0. *)
       let (_ : int) = Unix.lseek fd 0 Unix.SEEK_SET in
       lockf_until_granted fd)
;;

let acquire_base_path_lock_with
      ?(before_lease_commit = ignore)
      ?(contention = Refuse_when_owned)
      ~before_lease_open
      ~before_commit_identity_check
      ~before_runtime_identity_check
      ~run_dir
      base_path
  =
  match prepare_base_path_lock ~run_dir base_path with
  | Error rejection -> Base_path_rejected rejection
  | Ok prepared ->
    before_lease_open ();
    (* [lockf] locks are process-associated on POSIX, so a second descriptor in
       this process may successfully acquire the same kernel lock. The key is
       a full SHA-256 projection of the directory's (st_dev, st_ino) identity
       into the validated, current-UID private lease directory. A digest
       collision remains fail-closed because both identities contend on the
       same lease file. *)
    Mutex.protect base_path_lease_mu (fun () ->
      match Hashtbl.find_opt base_path_leases prepared.path with
      | Some (Active_lease _) ->
        (* NDT-OK: the OS process id is the observed owner identity. *)
        Base_path_already_owned
          { owner = Owner_this_process (Unix.getpid ()); lock_path = prepared.path }
      | Some (Failed_close (_, rejection)) -> Base_path_rejected rejection
      | None ->
        (* Cross-version exclusion with a server that predates the (st_dev,
           st_ino) keying is a documented operator step, not a technical
           fence: legacy_residue forbids keeping a legacy lease format alive,
           and a one-directional fence could not keep a v1-only server from
           starting a second lease for the same directory anyway. Stop the
           old server before starting this one across an upgrade. *)
        (match open_lease_file prepared with
         | Error rejection -> Base_path_rejected rejection
         | Ok fd ->
              let commit_outcome =
                try
                  before_lease_commit fd;
                  lock_lease_file ~contention fd;
                  Ok ()
                with
                | Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
                  let pid = parsed_pid_fd fd in
                  let v2_locked_by_other =
                    Base_path_already_owned
                      { owner = base_path_owner_of_recorded pid
                      ; lock_path = prepared.path
                      }
                  in
                  (match
                     close_acquisition_fd
                       ~operation:"close_contended_lease_file"
                       ~path:prepared.path
                       ~context:"kernel lease is owned by another process"
                       fd
                   with
                   | Ok () -> Error v2_locked_by_other
                   | Error rejection ->
                     Error (Base_path_rejected rejection))
                | exn ->
                  (* cancel-guard-ok: Unix.lockf performs no Eio operation. *)
                  (match
                     close_acquisition_fd
                       ~operation:"commit_base_path_lease"
                       ~path:prepared.path
                       ~context:(Printexc.to_string exn)
                       fd
                   with
                   | Error close_rejection ->
                     Error (Base_path_rejected close_rejection)
                   | Ok () ->
                     Error
                       (Base_path_rejected
                          (Lease_io_failed
                             { operation = "commit_base_path_lease"
                             ; path = prepared.path
                             ; reason = Printexc.to_string exn
                             })))
              in
              match commit_outcome with
              | Error result -> result
              | Ok () ->
                before_commit_identity_check ();
                (* Establish [.masc] only after the external lifetime lease is
                   held. OCaml's portable Unix surface has no directory-relative
                   no-follow open. The private lease directory blocks other-UID
                   path replacement; same-UID mutation remains an explicit
                   composition-root invariant tracked by #24344. *)
                (match verify_open_lease_file prepared fd None with
                  | Error rejection -> Base_path_rejected rejection
                  | Ok fd ->
                    (match establish_runtime_directory prepared with
                     | Error rejection ->
                       (match
                          close_acquisition_fd
                            ~operation:"close_failed_runtime_establishment"
                            ~path:prepared.path
                            ~context:
                              (base_path_lock_rejection_to_string rejection)
                            fd
                        with
                        | Ok () -> Base_path_rejected rejection
                        | Error close_rejection ->
                          Base_path_rejected close_rejection)
                     | Ok runtime_directory_stat ->
                       before_runtime_identity_check ();
                       (match
                          verify_directory_identity
                            ~path:prepared.runtime_directory
                            ~expected:runtime_directory_stat
                        with
                        | Error rejection ->
                          (match
                             close_acquisition_fd
                               ~operation:"close_retargeted_runtime_directory"
                               ~path:prepared.path
                               ~context:
                                 (base_path_lock_rejection_to_string rejection)
                               fd
                           with
                           | Ok () -> Base_path_rejected rejection
                           | Error close_rejection ->
                             Base_path_rejected close_rejection)
                        | Ok () ->
                          (* verify_open_lease_file closes the descriptor on
                             rejection itself; an outer close would race it
                             for EBADF. *)
                          (match verify_open_lease_file prepared fd None with
                           | Error rejection -> Base_path_rejected rejection
                           | Ok fd ->
                             (* NDT-OK: persist the OS lease holder identity
                                for operator observation. A write failure must
                                surface as a typed rejection with the descriptor
                                closed, not as an exception with the lease
                                locked and unregistered. *)
                             let commit_pid payload =
                               Unix.ftruncate fd 0;
                               let (_ : int) =
                                 Unix.lseek fd 0 Unix.SEEK_SET
                               in
                               write_all fd payload;
                               Unix.fsync fd
                             in
                             (match
                                try
                                  Ok (commit_pid (Printf.sprintf "%d\n" (Unix.getpid ())))
                                with
                                | exn ->
                                  (* cancel-guard-ok: Unix.ftruncate, Unix.lseek
                                     and Unix.fsync perform no Eio operation. *)
                                  Error (Printexc.to_string exn)
                              with
                              | Error reason ->
                                (match
                                   close_acquisition_fd
                                     ~operation:"close_failed_lease_commit"
                                     ~path:prepared.path
                                     ~context:reason
                                     fd
                                 with
                                 | Ok () ->
                                   Base_path_rejected
                                     (Lease_io_failed
                                        { operation = "commit_base_path_lease"
                                        ; path = prepared.path
                                        ; reason
                                        })
                                 | Error rejection ->
                                   Base_path_rejected rejection)
                              | Ok () ->
                                let lease = { fd; path = prepared.path } in
                                Hashtbl.add
                                  base_path_leases
                                  prepared.path
                                  (Active_lease lease);
                                Base_path_acquired lease)))))))
;;

let acquire_base_path_lock ~run_dir base_path =
  acquire_base_path_lock_with
    ~before_lease_open:(fun () -> ())
    ~before_commit_identity_check:(fun () -> ())
    ~before_runtime_identity_check:(fun () -> ())
    ~run_dir base_path
;;

type base_path_wait_refusal =
  | Another_replacement_waits of
      { waiter : base_path_owner
      ; waiter_path : string
      }

(* One waiter per workspace. A second waiter would queue behind whichever
   process the kernel hands the lease to next, so a later replacement could
   wait for a server nobody asked to stop and then start an older build. The
   waiter lock lives beside the lease, in the private directory
   [prepare_base_path_lock] has already validated. *)
let open_waiter_file prepared =
  let waiter_path = prepared.path ^ ".waiter" in
  match
    Unix.openfile waiter_path [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o600
  with
  | exception Unix.Unix_error (error, _, _) ->
    Error
      (Lease_io_failed
         { operation = "open_waiter_file"
         ; path = waiter_path
         ; reason = Unix.error_message error
         })
  | fd ->
    let stat = Unix.fstat fd in
    if stat.st_kind <> Unix.S_REG
    then (
      Unix.close fd;
      Error (Lease_file_non_regular { path = waiter_path; kind = stat.st_kind }))
    else if stat.st_nlink > 1
    then (
      Unix.close fd;
      Error (Lease_file_multiply_linked { path = waiter_path; links = stat.st_nlink }))
    else Ok (waiter_path, fd)
;;

let acquire_base_path_lock_after_owner_exits ~run_dir ~on_wait base_path =
  match prepare_base_path_lock ~run_dir base_path with
  | Error rejection -> Ok (Base_path_rejected rejection)
  | Ok prepared ->
    (match open_waiter_file prepared with
     | Error rejection -> Ok (Base_path_rejected rejection)
     | Ok (waiter_path, waiter_fd) ->
       Fun.protect
         ~finally:(fun () -> try Unix.close waiter_fd with Unix.Unix_error _ -> ())
         (fun () ->
           match Unix.lockf waiter_fd Unix.F_TLOCK 0 with
           | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
             Error
               (Another_replacement_waits
                  { waiter = base_path_owner_of_recorded (parsed_pid_fd waiter_fd)
                  ; waiter_path
                  })
           | () ->
             (match
                Unix.ftruncate waiter_fd 0;
                let (_ : int) = Unix.lseek waiter_fd 0 Unix.SEEK_SET in
                write_all waiter_fd (Printf.sprintf "%d\n" (Unix.getpid ()))
              with
              | exception Unix.Unix_error (error, _, _) ->
                Ok
                  (Base_path_rejected
                     (Lease_io_failed
                        { operation = "record_waiter"
                        ; path = waiter_path
                        ; reason = Unix.error_message error
                        }))
              | () ->
                Ok
                  (acquire_base_path_lock_with
                     ~contention:(Wait_for_release on_wait)
                     ~before_lease_open:(fun () -> ())
                     ~before_commit_identity_check:(fun () -> ())
                     ~before_runtime_identity_check:(fun () -> ())
                     ~run_dir
                     base_path))))
;;

module For_testing = struct
  let acquire_base_path_lock
        ?before_lease_commit
        ~before_lease_open
        ~before_commit_identity_check
        ~before_runtime_identity_check
        ~run_dir
        base_path
    =
    acquire_base_path_lock_with
      ?before_lease_commit
      ~contention:Refuse_when_owned
      ~before_lease_open
      ~before_commit_identity_check
      ~before_runtime_identity_check
      ~run_dir
      base_path
  ;;

  (* The v2 lease file of an already-canonical BasePath, name-only: nothing is
     opened or locked. *)
  let lease_path ~run_dir ~canonical_base_path =
    let owner_uid = Unix.geteuid () in
    let lease_directory =
      base_path_lease_directory ~run_dir ~owner_uid
    in
    (try Unix.mkdir lease_directory 0o700 with
     | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    Filename.concat
      lease_directory
      (Printf.sprintf
         "masc-base-path-owner-v2-%s.lease"
         (base_path_lock_digest_of_stats (Unix.stat canonical_base_path)))
end

type owner_capture_error =
  | Owner_lease_rejected of base_path_lock_rejection
  | Owner_identity_unavailable of Owner_process_identity.error
  | Current_process_owner
let capture_existing_owner ~run_dir ~base_path =
  match prepare_base_path_lock ~run_dir base_path with
  | Error rejection -> Error (Owner_lease_rejected rejection)
  | Ok prepared ->
    Mutex.protect base_path_lease_mu (fun () ->
      if Hashtbl.mem base_path_leases prepared.path then Error Current_process_owner
      else
        match open_lease_file prepared with
        | Error rejection -> Error (Owner_lease_rejected rejection)
        | Ok fd ->
          Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
            match Owner_process_identity.capture ~lease_fd:fd with
            | Ok owner -> Ok owner
            | Error other -> Error (Owner_identity_unavailable other)))
