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
  | Run_directory_creation_failed of
      { path : string
      ; reason : string
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
  | Announcement_port_invalid of { port : int }
  | Announcement_already_made of
      { path : string
      ; port : int
      }
  | Announcement_lease_not_active of { path : string }
  | Announcement_port_locked of
      { path : string
      ; port : int
      ; holder : int option
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
  | Run_directory_creation_failed { path; reason } ->
    Printf.sprintf
      "BasePath owner lease root creation failed path=%s error=%s"
      path
      reason
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
  | Announcement_port_invalid { port } ->
    Printf.sprintf "port announcement refused: %d is not a port" port
  | Announcement_already_made { path; port } ->
    Printf.sprintf
      "port announcement refused: this process already announces port %d path=%s"
      port
      path
  | Announcement_lease_not_active { path } ->
    Printf.sprintf
      "port announcement refused: the lease handle is not the active process owner \
       path=%s"
      path
  | Announcement_port_locked { path; port; holder = Some holder } ->
    Printf.sprintf
      "port announcement refused: the byte of port %d is locked by pid %d path=%s"
      port
      holder
      path
  | Announcement_port_locked { path; port; holder = None } ->
    Printf.sprintf
      "port announcement refused: the byte of port %d is locked by another process \
       path=%s"
      port
      path
;;

let base_path_lease_mu = Mutex.create ()

type retained_base_path_fd =
  | Active_lease of base_path_lease
  | Failed_close of base_path_lease * base_path_lock_rejection

let base_path_leases : (string, retained_base_path_fd) Hashtbl.t =
  Hashtbl.create 2
;;

(* The port a server serves, told to the host through the lock table of the
   kernel. The server locks one byte of a file beside its lease: the byte
   whose position is the port. The file stays empty. Another process asks
   the kernel with F_GETLK who holds the byte of a port
   ([Owner_process_identity.byte_holder]). The record is the lock, so it is
   gone the moment its holder is, and no number stays on disk to go stale as
   the one in a lease file does ([Owner_recorded]). *)
type announcing_server =
  | Account_server
  | Single_user_server

(* Each kind of server announces on a file of its own, so the lock of one
   kind never answers a reader that asks about the other. *)
let announcement_path server lease_path =
  match server with
  | Account_server -> lease_path ^ ".account-server"
  | Single_user_server -> lease_path ^ ".single-user-server"
;;

(* (kind of server, lease path) -> the descriptor that holds the lock, and
   the port. POSIX record locks belong to the process, and closing any
   descriptor of the file drops them. So this descriptor is the only one the
   announcing process has on the file: the reads below find it by the
   identity of the file and ask through it, and open nothing
   ([read_announcement]). *)
let announcements : (announcing_server * string, Unix.file_descr * int) Hashtbl.t =
  Hashtbl.create 2
;;

(* A close that fails leaves it open whether the descriptor is gone. It is
   said and not tried again: the number may already name another file. *)
let close_announcement_fd ~path fd =
  try Unix.close fd with
  | Unix.Unix_error (error, syscall, argument) ->
    Log.Server.error
      "port announcement close failed: path=%s error=%s syscall=%s argument=%s"
      path
      (Unix.error_message error)
      syscall
      argument
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

(* HIGH-RISK-UNREVIEWED: makes the directory every process of a BasePath
   trusts for its owner lease.
   Beside [.masc], not in it: a Fresh state that deletes [.masc] state while
   an owner runs must not take that owner's lease with it. *)
let lease_run_dir (root : Host_config.base_path_lease_root) ~base_path =
  match root with
  | Lease_dir_override dir -> Ok dir
  | Beside_base_path ->
    (match Unix.realpath base_path with
     | exception Unix.Unix_error (error, _, _) ->
       Error
         (Base_path_canonicalization_failed
            { base_path; reason = Unix.error_message error })
     | canonical_base_path ->
       let dir = Filename.concat canonical_base_path Common.owner_lease_dirname in
       (match Unix.mkdir dir private_lease_directory_permissions with
        | () -> Ok dir
        | exception Unix.Unix_error (Unix.EEXIST, _, _) -> Ok dir
        | exception Unix.Unix_error (error, _, _) ->
          Error
            (Run_directory_creation_failed
               { path = dir; reason = Unix.error_message error })))
;;

let base_path_lease_directory ~run_dir ~owner_uid =
  Filename.concat
    run_dir
    (Printf.sprintf "%s-%d" private_lease_directory_prefix owner_uid)
;;

(* The lease is named by the digest of the directory's own (st_dev, st_ino)
   identity, not of the canonical BasePath string. macOS answers
   [Unix.realpath] with two different strings for one directory
   (/private/tmp/X and /System/Volumes/Data/private/tmp/X), so a name taken
   from the string would let two servers hold two leases for the same
   directory. One directory has exactly one lease name on every supported
   platform. *)
let base_path_lock_digest_of_stats (stat : Unix.stats) =
  Printf.sprintf "masc-base-path-lease:%d:%d" stat.st_dev stat.st_ino
  |> Agent_core_sha256.digest_string |> Agent_core_sha256.to_hex
;;

(* The name of the lease file of a BasePath in its private lease directory. *)
let lease_file_name (base_path_stat : Unix.stats) =
  Printf.sprintf
    "masc-base-path-owner-v2-%s.lease"
    (base_path_lock_digest_of_stats base_path_stat)
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
      (* The announcements go first: nothing reads a port from a process that
         has given the workspace up. Closing a descriptor drops its lock. *)
      Hashtbl.filter_map_inplace
        (fun (server, announced_lease) ((announcement_fd, (_ : int)) as held) ->
          if String.equal announced_lease lease.path
          then (
            close_announcement_fd
              ~path:(announcement_path server announced_lease)
              announcement_fd;
            None)
          else Some held)
        announcements;
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
    ; path = Filename.concat lease_directory (lease_file_name base_path_stat)
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

let acquire_owner_lease root base_path =
  match lease_run_dir root ~base_path with
  | Error rejection -> Base_path_rejected rejection
  | Ok run_dir -> acquire_base_path_lock ~run_dir base_path
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

(* A waiter that won the slot, committed the lease, and exec'd (as [masc
   start] does between acquiring the lease and serving) re-enters this same
   acquisition post-exec with the lease file already naming it: the PID
   persists across exec. It must not re-contend the single waiter slot: a
   contender that grabbed the slot in the exec gap would otherwise kill the
   legitimate winner with Another_replacement_waits after it already won
   (2026-11-04 live incident). The lease record, not the process image, is
   what this keys on.

   Read-only and side-effect free: it never creates the lease file, never
   locks, and every unreadable or unparsable outcome falls through to the
   waiter path below. The bypass only skips the waiter slot (a
   liveness/queueing mechanism); the kernel lock in the inner acquire
   remains the real mutex, and that acquire re-validates everything before
   committing, so a TOCTOU'd read degrades to the pre-fix behavior rather
   than to a wrong owner. *)
let lease_file_names_self prepared =
  match observe_lease_path prepared.path with
  | Ok (Lease_path_regular _) ->
    (match
       try Ok (Unix.openfile prepared.path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0)
       with Unix.Unix_error _ -> Error ()
     with
     | Error () -> false
     | Ok fd ->
       Fun.protect
         ~finally:(fun () ->
           try Unix.close fd with Unix.Unix_error _ -> ())
         (fun () ->
           match parsed_pid_fd fd with
           | Some pid -> pid = Unix.getpid ()
           | None -> false))
  | Ok (Lease_path_missing | Lease_path_other _) | Error _ -> false
;;

let acquire_base_path_lock_after_owner_exits ~run_dir ~on_wait base_path =
  match prepare_base_path_lock ~run_dir base_path with
  | Error rejection -> Ok (Base_path_rejected rejection)
  | Ok prepared when lease_file_names_self prepared ->
    Ok
      (acquire_base_path_lock_with
         ~contention:Refuse_when_owned
         ~before_lease_open:(fun () -> ())
         ~before_commit_identity_check:(fun () -> ())
         ~before_runtime_identity_check:(fun () -> ())
         ~run_dir
         base_path)
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
    Filename.concat lease_directory (lease_file_name (Unix.stat canonical_base_path))
end

type owner_capture_error =
  | Owner_lease_rejected of base_path_lock_rejection
  | Owner_identity_unavailable of Owner_process_identity.error
  | Current_process_owner

let owner_capture_error_to_string = function
  | Owner_lease_rejected rejection -> base_path_lock_rejection_to_string rejection
  | Owner_identity_unavailable Owner_process_identity.No_owner -> "no process holds the lease"
  | Owner_identity_unavailable Owner_process_identity.Owner_changed ->
    "the process that holds the lease changed while it was read"
  | Owner_identity_unavailable Owner_process_identity.Unsupported ->
    "this system gives no handle on the process that holds the lease"
  | Owner_identity_unavailable Owner_process_identity.Unavailable ->
    "the process that holds the lease could not be identified"
  | Owner_identity_unavailable Owner_process_identity.Closed ->
    "the handle on the process that holds the lease is closed"
  | Current_process_owner -> "this process holds the lease"
;;

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

(* HIGH-RISK-UNREVIEWED: a reader takes [false] for "nobody holds this
   BasePath", and reads no owner. The path is the one [lease_run_dir] and
   [prepare_base_path_lock] spell: the run directory by its real path, the
   private lease directory of the effective user under it, and the name of
   the lease file. Nothing of an entry is judged here. An entry on the way
   that is no directory answers [true], because the capture that follows
   refuses it in its own words and makes nothing under it. *)
let lease_file_present (root : Host_config.base_path_lease_root) ~base_path =
  let unread ~operation ~path error =
    Error (Lease_io_failed { operation; path; reason = Unix.error_message error })
  in
  (* [inside] goes on under a directory. *)
  let entry ~operation path ~inside =
    match Unix.lstat path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
    | exception Unix.Unix_error (error, _, _) -> unread ~operation ~path error
    | stat when stat.Unix.st_kind = Unix.S_DIR -> inside stat
    | (_ : Unix.stats) -> Ok true
  in
  match Unix.realpath base_path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | exception Unix.Unix_error (error, _, _) ->
    Error (Base_path_canonicalization_failed { base_path; reason = Unix.error_message error })
  | canonical_base_path ->
    entry ~operation:"lstat_base_path" canonical_base_path ~inside:(fun base_path_stat ->
      let run_dir =
        match root with
        | Lease_dir_override dir -> dir
        | Beside_base_path -> Filename.concat canonical_base_path Common.owner_lease_dirname
      in
      match Unix.realpath run_dir with
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
      | exception Unix.Unix_error (error, _, _) ->
        Error
          (Run_directory_canonicalization_failed { run_dir; reason = Unix.error_message error })
      | run_directory ->
        entry ~operation:"lstat_run_directory" run_directory ~inside:(fun (_ : Unix.stats) ->
          let lease_directory =
            base_path_lease_directory ~run_dir:run_directory ~owner_uid:(Unix.geteuid ())
          in
          entry
            ~operation:"inspect_private_lease_directory"
            lease_directory
            ~inside:(fun (_ : Unix.stats) ->
              let path = Filename.concat lease_directory (lease_file_name base_path_stat) in
              match Unix.lstat path with
              | (_ : Unix.stats) -> Ok true
              | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
              | exception Unix.Unix_error (error, _, _) ->
                unread ~operation:"lstat_lease_file" ~path error)))
;;

type account_server_announcement =
  { pid : int
  ; port : int
  }

type single_user_server_announcement = account_server_announcement

let announcement_failed ~operation ~path reason =
  Error (Lease_io_failed { operation; path; reason })
;;

(* The file behind [fd] is a regular file of this user with one name. [seen]
   is what [lstat] said of the path before the open: a file that was there
   must still be that one. The descriptor is closed on a rejection. *)
let checked_announcement_fd ~path ~seen fd =
  let reject rejection =
    close_announcement_fd ~path fd;
    Error rejection
  in
  match Unix.fstat fd with
  | exception Unix.Unix_error (error, _, _) ->
    reject
      (Lease_io_failed
         { operation = "fstat_port_announcement"
         ; path
         ; reason = Unix.error_message error
         })
  | stat ->
    let effective_uid = Unix.geteuid () in
    if stat.st_kind <> Unix.S_REG
    then reject (Lease_file_non_regular { path; kind = stat.st_kind })
    else if stat.st_nlink > 1
    then reject (Lease_file_multiply_linked { path; links = stat.st_nlink })
    else if stat.st_uid <> effective_uid
    then
      reject
        (Lease_file_wrong_owner
           { path; expected_uid = effective_uid; observed_uid = stat.st_uid })
    else (
      match seen with
      | Some seen when not (same_file_identity seen stat) ->
        reject (Lease_identity_changed { path })
      | Some (_ : Unix.stats) | None -> Ok fd)
;;

let open_announcement_to_lock path =
  let opened ~operation ~flags ~permissions ~seen =
    match Unix.openfile path (Unix.O_RDWR :: Unix.O_CLOEXEC :: flags) permissions with
    | fd -> checked_announcement_fd ~path ~seen fd
    | exception Unix.Unix_error (error, _, _) ->
      announcement_failed ~operation ~path (Unix.error_message error)
  in
  match observe_lease_path path with
  | Error rejection -> Error rejection
  | Ok (Lease_path_other kind) -> Error (Lease_file_non_regular { path; kind })
  | Ok (Lease_path_regular seen) ->
    opened
      ~operation:"open_port_announcement"
      ~flags:[]
      ~permissions:0
      ~seen:(Some seen)
  | Ok Lease_path_missing ->
    opened
      ~operation:"create_port_announcement"
      ~flags:[ Unix.O_CREAT; Unix.O_EXCL ]
      ~permissions:0o600
      ~seen:None
;;

(* HIGH-RISK-UNREVIEWED: a command line takes the holder of this lock for the
   server of the workspace, and decides from it which process gets the
   bearer of the workspace (#51075). Only the active lease of this process
   announces here, on the file of [server] and at the byte of [port]; the
   caller gives the port its listener bound. A lock on the wrong file or
   byte would send that bearer to whatever process serves the port. *)
let announce server (lease : base_path_lease) ~port =
  let path = announcement_path server lease.path in
  let failed = announcement_failed ~operation:"announce_port" ~path in
  match Workspace_connection.port port with
  | Error (_ : Workspace_connection.error) -> Error (Announcement_port_invalid { port })
  | Ok (_ : Workspace_connection.port) ->
    Mutex.protect base_path_lease_mu (fun () ->
      match Hashtbl.find_opt base_path_leases lease.path with
      | Some (Active_lease current) when current == lease ->
        (match Hashtbl.find_opt announcements (server, lease.path) with
         | Some ((_ : Unix.file_descr), announced) ->
           Error (Announcement_already_made { path; port = announced })
         | None ->
           (* The private directory was validated when the lease was taken.
              The lease path must still name the file this process holds
              locked: a directory that was moved or replaced since then holds
              no announcement of this owner. *)
           (match Unix.fstat lease.fd, Unix.lstat lease.path with
            | exception Unix.Unix_error (error, _, _) -> failed (Unix.error_message error)
            | held, named when not (same_file_identity held named) ->
              Error (Lease_identity_changed { path = lease.path })
            | (_ : Unix.stats), (_ : Unix.stats) ->
              (match open_announcement_to_lock path with
               | Error rejection -> Error rejection
               | Ok fd ->
                 (match
                    let (_ : int) = Unix.lseek fd port Unix.SEEK_SET in
                    Unix.lockf fd Unix.F_TLOCK 1
                  with
                  | () ->
                    Hashtbl.replace announcements (server, lease.path) (fd, port);
                    Ok ()
                  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) ->
                    (* Another process holds a lock over the byte. This
                       descriptor holds none, so the kernel can be asked
                       which process before it is closed. It names no process
                       when the lock is not the write lock of that one byte. *)
                    let holder =
                      match Owner_process_identity.byte_holder fd ~byte:port with
                      | Ok holder -> holder
                      | Error (_ : Owner_process_identity.error) -> None
                    in
                    close_announcement_fd ~path fd;
                    Error (Announcement_port_locked { path; port; holder })
                  | exception Unix.Unix_error (error, _, _) ->
                    close_announcement_fd ~path fd;
                    failed (Unix.error_message error)))))
      | Some (Active_lease _) | Some (Failed_close _) | None ->
        Error (Announcement_lease_not_active { path = lease.path }))
;;

let announce_account_server = announce Account_server
let announce_single_user_server = announce Single_user_server

(* How this process may ask the kernel about an announcement file. *)
type announcement_reader =
  | Announces_here of Unix.file_descr * int
  (** This process announces the port on the file. The descriptor is the one
      that holds its lock, and the only one it may have on the file. *)
  | Reads_through of Unix.file_descr
  (** Another process announces on the file, or none does. The descriptor
      was opened for this read and is closed after it. *)

(* The announcement this process holds on the file that [seen] names. The
   table is keyed by the lease path as this process spelled it, and one
   directory has more than one spelling ([base_path_lock_digest_of_stats]):
   the file is compared, not the string, and so is every announcement of
   this process, of either kind. A read that found none for a file this
   process locks would open a second descriptor on it, and its close would
   drop the announcement. *)
let own_announcement_on seen =
  Hashtbl.fold
    (fun (_ : announcing_server * string) (fd, port) found ->
      match found with
      | Some (_ : Unix.file_descr * int) -> found
      | None -> if same_file_identity seen (Unix.fstat fd) then Some (fd, port) else None)
    announcements
    None
;;

(* One read of the announcement file of [server] for [base_path]. [absent]
   is the answer when no file is there: a read makes no file. The file is
   opened with the checks of a lease file. *)
let read_announcement server ~operation ~run_dir ~base_path ~absent read =
  match prepare_base_path_lock ~run_dir base_path with
  | Error rejection -> Error rejection
  | Ok prepared ->
    let path = announcement_path server prepared.path in
    let failed = announcement_failed ~operation ~path in
    Mutex.protect base_path_lease_mu (fun () ->
      match observe_lease_path path with
      | Error rejection -> Error rejection
      | Ok Lease_path_missing -> Ok absent
      | Ok (Lease_path_other kind) -> Error (Lease_file_non_regular { path; kind })
      | Ok (Lease_path_regular seen) ->
        (match own_announcement_on seen with
         | exception Unix.Unix_error (error, _, _) -> failed (Unix.error_message error)
         | Some (fd, port) -> read ~failed (Announces_here (fd, port))
         | None ->
           (match open_existing_lease_file { prepared with path } seen with
            | Error rejection -> Error rejection
            | Ok fd ->
              Fun.protect
                ~finally:(fun () -> close_announcement_fd ~path fd)
                (fun () -> read ~failed (Reads_through fd)))))
;;

let kernel_not_asked failed = failed "the kernel could not be asked about the lock"

let port_holder server ~run_dir ~base_path ~port =
  let operation = "read_port_holder" in
  match Workspace_connection.port port with
  | Error (_ : Workspace_connection.error) -> Error (Announcement_port_invalid { port })
  | Ok (_ : Workspace_connection.port) ->
    read_announcement server ~operation ~run_dir ~base_path ~absent:None (fun ~failed reader ->
      match reader with
      | Announces_here ((_ : Unix.file_descr), announced) when announced = port ->
        (* NDT-OK: the OS process id is the observed holder identity. *)
        Ok (Some (Unix.getpid ()))
      | Announces_here (fd, (_ : int)) | Reads_through fd ->
        (match Owner_process_identity.byte_holder fd ~byte:port with
         | Ok holder -> Ok holder
         | Error (_ : Owner_process_identity.error) -> kernel_not_asked failed))
;;

let account_server_port_holder = port_holder Account_server
let single_user_server_port_holder = port_holder Single_user_server

let whole_file_announcement server ~run_dir ~base_path =
  read_announcement
    server
    ~operation:"read_port_announcement"
    ~run_dir
    ~base_path
    ~absent:None
    (fun ~failed reader ->
      match reader with
      | Announces_here ((_ : Unix.file_descr), port) ->
        (* NDT-OK: the OS process id is the observed holder identity. *)
        Ok (Some { pid = Unix.getpid (); port })
      | Reads_through fd ->
        (match Owner_process_identity.held_byte fd with
         | Ok None -> Ok None
         | Ok (Some { holder; byte }) ->
           (* No server announces outside the ports ([announce]), so a lock
              there is no announcement. *)
           (match Workspace_connection.port byte with
            | Ok (_ : Workspace_connection.port) -> Ok (Some { pid = holder; port = byte })
            | Error (_ : Workspace_connection.error) -> Ok None)
         | Error (_ : Owner_process_identity.error) -> kernel_not_asked failed))
;;

let account_server_announcement = whole_file_announcement Account_server
let single_user_server_announcement = whole_file_announcement Single_user_server
