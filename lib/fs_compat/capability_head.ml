type target_fingerprint =
  { dev : int64
  ; ino : int64
  ; length : int64
  ; sha256 : string
  }

type cursor =
  { parent_dev : int64
  ; parent_ino : int64
  ; leaf : string
  ; lock_dev : int64
  ; lock_ino : int64
  ; lock_epoch : string
  ; target : target_fingerprint option
  }

type operation =
  | Pin_parent
  | Open_lock
  | Acquire_cross_process_lock
  | Read_lock_marker
  | Initialize_lock_marker
  | Read_head
  | Create_stage
  | Write_stage
  | Sync_stage
  | Close_stage
  | Revalidate
  | Rename_head
  | Sync_parent
  | Verify_publication
  | Cleanup_stage
  | Settle_resources

type diagnostic =
  { operation : operation
  ; detail : string
  }

type settlement_warning =
  | Cleanup_failed of diagnostic
  | Resource_settlement_failed of diagnostic

type snapshot =
  { row : string option
  ; cursor : cursor
  ; settlement_warnings : settlement_warning list
  }

let snapshot_row snapshot = snapshot.row
let snapshot_cursor snapshot = snapshot.cursor
type error =
  | Invalid_leaf of string
  | Invalid_row of string
  | Busy
  | Conflict of snapshot
  | Corrupt_lock of string
  | Corrupt_head of string
  | Unsupported of string
  | Io_error of diagnostic

type publication_evidence =
  { expected_cursor : cursor
  ; intended_sha256 : string
  ; intended_length : int64
  ; published_cursor : cursor
  }

type publication_indeterminate =
  { expected_cursor : cursor
  ; intended_sha256 : string
  ; intended_length : int64
  ; observed : cursor option
  }

type target_effect =
  | Unchanged
  | Published of publication_evidence
  | Publication_indeterminate of publication_indeterminate

type failure =
  { error : error
  ; target_effect : target_effect
  ; settlement_warnings : settlement_warning list
  }

type publication =
  { evidence : publication_evidence
  ; settlement_warnings : settlement_warning list
  }

let publication_evidence publication = publication.evidence
let publication_settlement_warnings publication = publication.settlement_warnings

let max_row_bytes = 64 * 1024
let max_lock_marker_bytes = 128
let lock_magic = "MASC-CAPABILITY-HEAD-LOCK-v2"
let internal_leaf_prefix = ".masc-capability-head-"

let ( let* ) result fn =
  match result with
  | Ok value -> fn value
  | Error error -> Error error

module Lease = struct
  module Key = struct
    type t = int64 * int64 * string

    let equal (left_dev, left_ino, left_leaf) (right_dev, right_ino, right_leaf) =
      Int64.equal left_dev right_dev
      && Int64.equal left_ino right_ino
      && String.equal left_leaf right_leaf

    let hash = Hashtbl.hash
  end

  module Held = Hashtbl.Make (Key)

  let mutex = Mutex.create ()
  let held = Held.create 32

  let try_acquire ~parent_dev ~parent_ino ~leaf =
    let key = parent_dev, parent_ino, leaf in
    Mutex.protect mutex (fun () ->
      if Held.mem held key
      then None
      else (
        Held.add held key ();
        Some key))

  let release token =
    Mutex.protect mutex (fun () ->
      if not (Held.mem held token)
      then invalid_arg "Capability_head.Lease.release: token is not held";
      Held.remove held token)
end

(* [Eio.Path.open_out ~sw] gives the switch ownership of the descriptor and
   of the lock held on it. *)
type lock_handle =
  { path : Eio.Fs.dir_ty Eio.Path.t
  ; stat : Eio.File.Stat.t
  ; epoch : string
  }

type hooks =
  { after_lock_acquired : unit -> unit
  ; before_rename : unit -> unit
  ; after_rename : unit -> unit
  ; after_parent_sync : unit -> unit
  ; after_verified : unit -> unit
  ; before_stage_cleanup : unit -> unit
  ; on_resource_settlement : unit -> unit
  }

let no_hooks =
  { after_lock_acquired = (fun () -> ())
  ; before_rename = (fun () -> ())
  ; after_rename = (fun () -> ())
  ; after_parent_sync = (fun () -> ())
  ; after_verified = (fun () -> ())
  ; before_stage_cleanup = (fun () -> ())
  ; on_resource_settlement = (fun () -> ())
  }

type transaction_effect =
  | Before_publication
  | Renamed of publication_indeterminate
  | Durable of publication_evidence

exception Hook_failed of diagnostic

let sha256 value = Digestif.SHA256.(to_hex (digest_string value))
let exception_detail exn = Printexc.to_string exn

let diagnostic operation exn =
  { operation; detail = exception_detail exn }

let reraise_fatal exn raw_backtrace =
  match exn with
  | Out_of_memory | Stack_overflow | Sys.Break ->
    Printexc.raise_with_backtrace exn raw_backtrace
  | _ -> ()

let protect_io operation fn =
  try Ok (fn ()) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let raw_backtrace = Printexc.get_raw_backtrace () in
    reraise_fatal exn raw_backtrace;
    Error (Io_error (diagnostic operation exn))

let protect_result operation fn =
  try fn () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let raw_backtrace = Printexc.get_raw_backtrace () in
    reraise_fatal exn raw_backtrace;
    Error (Io_error (diagnostic operation exn))

let invoke_hook operation hook =
  try hook () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let raw_backtrace = Printexc.get_raw_backtrace () in
    reraise_fatal exn raw_backtrace;
    raise (Hook_failed (diagnostic operation exn))

let diagnostic_of_exception default_operation = function
  | Hook_failed diagnostic -> diagnostic
  | exn -> diagnostic default_operation exn

let failure ?(target_effect = Unchanged) error =
  { error; target_effect; settlement_warnings = [] }

let target_effect_of_transaction = function
  | Before_publication -> Unchanged
  | Renamed evidence -> Publication_indeterminate evidence
  | Durable evidence -> Published evidence

let failure_for_effect publication_state error =
  failure ~target_effect:(target_effect_of_transaction publication_state) error

let validate_leaf leaf =
  let normalized_leaf = String.lowercase_ascii leaf in
  if String.equal leaf ""
     || String.equal leaf "."
     || String.equal leaf ".."
     || String.starts_with ~prefix:internal_leaf_prefix normalized_leaf
     || String.exists (fun char -> Char.equal char '/' || Char.equal char '\000') leaf
  then Error (Invalid_leaf leaf)
  else Ok ()

let validate_row row =
  if String.equal row ""
  then Error (Invalid_row "HEAD row must be non-empty")
  else if String.length row > max_row_bytes
  then Error (Invalid_row "HEAD row exceeds max_row_bytes")
  else if String.exists (fun char -> Char.equal char '\n' || Char.equal char '\r') row
  then Error (Invalid_row "HEAD row must not contain CR or LF")
  else Ok ()

let lock_leaf leaf =
  internal_leaf_prefix ^ sha256 leaf ^ ".lock"

let marker epoch =
  Printf.sprintf "%s %s\n" lock_magic epoch

(* The canonical predicate, not a fourth copy of it. [masc_string_util] was
   extracted to be dependency-free precisely so a caller could reach it
   without taking masc_core's edges; its own dune says the private copies
   exist because that cost used to be real, and it is not any more. *)
let is_lower_hex = String_util.is_lowercase_sha256_hex

let parse_marker value =
  let length = String.length value in
  if length = 0
  then Error (Corrupt_lock "stable lock marker is empty")
  else if not (Char.equal value.[length - 1] '\n')
  then Error (Corrupt_lock "stable lock marker is not LF-terminated")
  else
    let body = String.sub value 0 (length - 1) in
    if String.exists (fun char -> Char.equal char '\n' || Char.equal char '\r') body
    then Error (Corrupt_lock "stable lock marker contains multiple rows or CR")
    else
      match String.split_on_char ' ' body with
      | [ magic; epoch ] when String.equal magic lock_magic && is_lower_hex epoch ->
        Ok epoch
      | _ -> Error (Corrupt_lock "stable lock marker has an invalid shape")

let same_identity (left : Eio.File.Stat.t) (right : Eio.File.Stat.t) =
  Int64.equal left.dev right.dev && Int64.equal left.ino right.ino

let same_open_file (left : Eio.File.Stat.t) (right : Eio.File.Stat.t) =
  same_identity left right
  && Int64.equal
       (Optint.Int63.to_int64 left.size)
       (Optint.Int63.to_int64 right.size)

let validate_private_regular ~what ~corrupt (stat : Eio.File.Stat.t) =
  if stat.kind <> `Regular_file
  then Error (corrupt (what ^ " is not a regular file"))
  else if not (Int64.equal stat.nlink 1L)
  then Error (corrupt (what ^ " must have exactly one hard link"))
  else if stat.perm land 0o7777 <> 0o600
  then Error (corrupt (what ^ " must have mode 0600 and no special bits"))
  else Ok ()

let verify_path_binding ~path ~opened_stat ~what ~corrupt =
  match Eio.Path.kind ~follow:false path with
  | `Regular_file ->
    let path_stat = Eio.Path.stat ~follow:false path in
    if same_identity opened_stat path_stat
    then Ok ()
    else Error (corrupt (what ^ " path no longer names the opened inode"))
  | `Not_found -> Error (corrupt (what ^ " path disappeared"))
  | `Symbolic_link -> Error (corrupt (what ^ " path is a symbolic link"))
  | _ -> Error (corrupt (what ^ " path is not a regular file"))

let read_open_file ~max_bytes ~operation ~what ~corrupt file =
  protect_result operation (fun () ->
    let before = Eio.File.stat file in
    let size64 = Optint.Int63.to_int64 before.size in
    if Int64.compare size64 0L < 0
    then Error (corrupt (what ^ " has a negative size"))
    else if Int64.compare size64 (Int64.of_int max_bytes) > 0
    then Error (corrupt (what ^ " exceeds its byte bound"))
    else
      let size = Int64.to_int size64 in
      let buffer = Cstruct.create size in
      if size > 0
      then
        Eio.File.pread_exact
          file
          ~file_offset:(Optint.Int63.of_int 0)
          [ buffer ];
      let after = Eio.File.stat file in
      if not (same_open_file before after)
      then Error (corrupt (what ^ " changed while it was being read"))
      else Ok (Cstruct.to_string buffer, after))

let sync_parent parent =
  let resource, _relative = parent in
  match Eio_unix.Resource.fd_opt resource with
  | None -> Error (Unsupported "parent directory capability has no Unix file descriptor")
  | Some fd ->
    protect_io Sync_parent (fun () ->
      Eio_unix.Fd.use_exn "capability_head.sync_parent" fd (fun raw_fd ->
        Eio_unix.run_in_systhread
          ~label:"capability_head.sync_parent"
          (fun () -> Unix.fsync raw_fd)))

let try_lock file =
  match Eio_unix.Resource.fd_opt file with
  | None -> Error (Unsupported "stable lock has no Unix file descriptor")
  | Some fd ->
    (try
       Eio_unix.Fd.use_exn "capability_head.try_lock" fd (fun raw_fd ->
         Eio_unix.run_in_systhread
           ~label:"capability_head.try_lock"
           (fun () ->
             let _position = Unix.lseek raw_fd 0 Unix.SEEK_SET in
             Unix.lockf raw_fd Unix.F_TLOCK 0));
       Ok ()
     with
     | Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> Error Busy
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       let raw_backtrace = Printexc.get_raw_backtrace () in
       reraise_fatal exn raw_backtrace;
       Error (Io_error (diagnostic Acquire_cross_process_lock exn)))

let fresh_epoch secure_random =
  protect_io Initialize_lock_marker (fun () ->
    let bytes = Cstruct.create 32 in
    Eio.Flow.read_exact secure_random bytes;
    sha256 (Cstruct.to_string bytes))

let write_initial_marker file epoch =
  protect_io Initialize_lock_marker (fun () ->
    let _position = Eio.File.seek file (Optint.Int63.of_int 0) `Set in
    Eio.Flow.copy_string (marker epoch) file;
    Eio.File.sync file)

let open_lock ~sw ~secure_random ~parent ~leaf =
  protect_result Open_lock (fun () ->
    let target_path = Eio.Path.(parent / leaf) in
    let path = Eio.Path.(parent / lock_leaf leaf) in
    match Eio.Path.kind ~follow:false path with
    | (`Not_found | `Regular_file) ->
      let file = Eio.Path.open_out ~sw ~create:(`If_missing 0o600) path in
      let* () = try_lock file in
      let opened_stat = Eio.File.stat file in
      let* () =
        validate_private_regular
          ~what:"stable lock"
          ~corrupt:(fun detail -> Corrupt_lock detail)
          opened_stat
      in
      let* () =
        verify_path_binding
          ~path
          ~opened_stat
          ~what:"stable lock"
          ~corrupt:(fun detail -> Corrupt_lock detail)
      in
      let* contents, _ =
        read_open_file
          ~max_bytes:max_lock_marker_bytes
          ~operation:Read_lock_marker
          ~what:"stable lock marker"
          ~corrupt:(fun detail -> Corrupt_lock detail)
          file
      in
      if not (String.equal contents "")
      then
        let* epoch = parse_marker contents in
        Ok { path; stat = opened_stat; epoch }
      else
        (match Eio.Path.kind ~follow:false target_path with
         | `Not_found ->
           let* () = protect_io Initialize_lock_marker (fun () -> Eio.File.sync file) in
           let* () = sync_parent parent in
           let* epoch = fresh_epoch secure_random in
           let* () = write_initial_marker file epoch in
           Ok { path; stat = opened_stat; epoch }
         | _ ->
           Error (Corrupt_lock "empty stable lock exists beside a present HEAD"))
    | `Symbolic_link -> Error (Corrupt_lock "stable lock path is a symbolic link")
    | _ -> Error (Corrupt_lock "stable lock path is not a regular file"))

let parse_head_payload payload =
  let length = String.length payload in
  if length < 2
  then Error (Corrupt_head "HEAD must contain one non-empty LF-terminated row")
  else if not (Char.equal payload.[length - 1] '\n')
  then Error (Corrupt_head "HEAD is not LF-terminated")
  else
    let row = String.sub payload 0 (length - 1) in
    if String.length row > max_row_bytes
    then Error (Corrupt_head "HEAD row exceeds max_row_bytes")
    else if String.exists (fun char -> Char.equal char '\n' || Char.equal char '\r') row
    then Error (Corrupt_head "HEAD contains multiple rows or CR")
    else Ok row

let read_target ~sw ~parent ~leaf =
  protect_result Read_head (fun () ->
    let path = Eio.Path.(parent / leaf) in
    match Eio.Path.kind ~follow:false path with
    | `Not_found -> Ok None
    | `Regular_file ->
      let file = Eio.Path.open_in ~sw path in
      let opened_stat = Eio.File.stat file in
      let* () =
        validate_private_regular
          ~what:"HEAD"
          ~corrupt:(fun detail -> Corrupt_head detail)
          opened_stat
      in
      let* () =
        verify_path_binding
          ~path
          ~opened_stat
          ~what:"HEAD"
          ~corrupt:(fun detail -> Corrupt_head detail)
      in
      let* payload, final_stat =
        read_open_file
          ~max_bytes:(max_row_bytes + 1)
          ~operation:Read_head
          ~what:"HEAD"
          ~corrupt:(fun detail -> Corrupt_head detail)
          file
      in
      let* () =
        verify_path_binding
          ~path
          ~opened_stat:final_stat
          ~what:"HEAD"
          ~corrupt:(fun detail -> Corrupt_head detail)
      in
      let* row = parse_head_payload payload in
      let fingerprint =
        { dev = final_stat.dev
        ; ino = final_stat.ino
        ; length = Int64.of_int (String.length payload)
        ; sha256 = sha256 payload
        }
      in
      Ok (Some (row, fingerprint))
    | `Symbolic_link -> Error (Corrupt_head "HEAD path is a symbolic link")
    | _ -> Error (Corrupt_head "HEAD path is not a regular file"))

let make_cursor ~parent_stat ~leaf ~lock ~target =
  { parent_dev = parent_stat.Eio.File.Stat.dev
  ; parent_ino = parent_stat.ino
  ; leaf
  ; lock_dev = lock.stat.dev
  ; lock_ino = lock.stat.ino
  ; lock_epoch = lock.epoch
  ; target
  }

let read_current ~sw ~parent ~parent_stat ~leaf ~lock =
  let* target = read_target ~sw ~parent ~leaf in
  match target with
  | None ->
    let cursor = make_cursor ~parent_stat ~leaf ~lock ~target:None in
    Ok { row = None; cursor; settlement_warnings = [] }
  | Some (row, fingerprint) ->
    let cursor = make_cursor ~parent_stat ~leaf ~lock ~target:(Some fingerprint) in
    Ok { row = Some row; cursor; settlement_warnings = [] }

(* Field by field, not [=]: an [option] of a record compared structurally
   says nothing about which part differed, and reading the fields is what
   proves they are load-bearing. *)
let target_fingerprint_equal left right =
  Int64.equal left.dev right.dev
  && Int64.equal left.ino right.ino
  && Int64.equal left.length right.length
  && String.equal left.sha256 right.sha256

let cursor_equal left right =
  Int64.equal left.parent_dev right.parent_dev
  && Int64.equal left.parent_ino right.parent_ino
  && String.equal left.leaf right.leaf
  && Int64.equal left.lock_dev right.lock_dev
  && Int64.equal left.lock_ino right.lock_ino
  && String.equal left.lock_epoch right.lock_epoch
  && Option.equal target_fingerprint_equal left.target right.target

let fresh_stage_leaf secure_random =
  protect_io Create_stage (fun () ->
    let entropy = Cstruct.create 32 in
    Eio.Flow.read_exact secure_random entropy;
    internal_leaf_prefix ^ "stage-" ^ sha256 (Cstruct.to_string entropy))

let rec create_stage ~sw ~secure_random ~parent attempts =
  if attempts = 0
  then Error (Io_error { operation = Create_stage; detail = "stage namespace exhausted" })
  else
    let* stage_leaf = fresh_stage_leaf secure_random in
    let path = Eio.Path.(parent / stage_leaf) in
    (try
       let file = Eio.Path.open_out ~sw ~create:(`Exclusive 0o600) path in
       Ok (path, file)
     with
     | Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) ->
       create_stage ~sw ~secure_random ~parent (attempts - 1)
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       let raw_backtrace = Printexc.get_raw_backtrace () in
       reraise_fatal exn raw_backtrace;
       Error (Io_error (diagnostic Create_stage exn)))

let write_stage ~path file payload =
  let* () = protect_io Write_stage (fun () -> Eio.Flow.copy_string payload file) in
  let* () = protect_io Sync_stage (fun () -> Eio.File.sync file) in
  protect_result Sync_stage (fun () ->
    let opened_stat = Eio.File.stat file in
    let* () =
      validate_private_regular
        ~what:"stage"
        ~corrupt:(fun detail -> Io_error { operation = Sync_stage; detail })
        opened_stat
    in
    if
      not
        (Int64.equal
           (Optint.Int63.to_int64 opened_stat.size)
           (Int64.of_int (String.length payload)))
    then Error (Io_error { operation = Sync_stage; detail = "stage size mismatch" })
    else
      let* () =
        verify_path_binding
          ~path
          ~opened_stat
          ~what:"stage"
          ~corrupt:(fun detail -> Io_error { operation = Sync_stage; detail })
      in
      Ok opened_stat)

let verify_lock_binding lock =
  verify_path_binding
    ~path:lock.path
    ~opened_stat:lock.stat
    ~what:"stable lock"
    ~corrupt:(fun detail -> Corrupt_lock detail)

let normalize_result ~warnings ~set_success_warnings = function
  | Ok value -> Ok (set_success_warnings value warnings)
  | Error (failed : failure) ->
    Error
      { failed with
        settlement_warnings = failed.settlement_warnings @ warnings
      }

let run_transaction ~hooks ~parent ~leaf ~publication_state ~set_success_warnings transaction =
  Eio.Fiber.check ();
  let token = ref None in
  let completed = ref None in
  let warnings = ref [] in
  Fun.protect
    ~finally:(fun () -> Option.iter Lease.release !token)
    (fun () ->
      try
        Eio.Switch.run_protected (fun sw ->
          Eio.Switch.on_release sw (fun () ->
            try hooks.on_resource_settlement () with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
              let raw_backtrace = Printexc.get_raw_backtrace () in
              reraise_fatal exn raw_backtrace;
              raise (Hook_failed (diagnostic Settle_resources exn)));
          let exact_parent, parent_stat =
            try
              let exact_parent = Eio.Path.open_dir ~sw parent in
              exact_parent, Eio.Path.stat ~follow:false exact_parent
            with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
              let raw_backtrace = Printexc.get_raw_backtrace () in
              reraise_fatal exn raw_backtrace;
              raise (Hook_failed (diagnostic Pin_parent exn))
          in
          match
            Lease.try_acquire
              ~parent_dev:parent_stat.dev
              ~parent_ino:parent_stat.ino
              ~leaf
          with
          | None ->
            let result = Error (failure Busy) in
            completed := Some result;
            result
          | Some acquired ->
            token := Some acquired;
            let result = transaction ~sw ~parent:exact_parent ~parent_stat ~warnings in
            let result =
              normalize_result
                ~warnings:(List.rev !warnings)
                ~set_success_warnings
                result
            in
            completed := Some result;
            result)
      with
      | Eio.Cancel.Cancelled _ as exn
        when !publication_state = Before_publication && Option.is_none !completed ->
        raise exn
      | exn ->
        let raw_backtrace = Printexc.get_raw_backtrace () in
        reraise_fatal exn raw_backtrace;
        let detail = diagnostic_of_exception Settle_resources exn in
        (match !completed with
         | Some (Ok value) ->
           Ok (set_success_warnings value [ Resource_settlement_failed detail ])
         | Some (Error failure) ->
           Error
             { failure with
               settlement_warnings =
                 failure.settlement_warnings @ [ Resource_settlement_failed detail ]
             }
         | None ->
           Error
             { (failure_for_effect !publication_state (Io_error detail)) with
               settlement_warnings = List.rev !warnings
             }))

let read ~secure_random ~parent ~leaf =
  match validate_leaf leaf with
  | Error error -> Error (failure error)
  | Ok () ->
    let publication_state = ref Before_publication in
    run_transaction
      ~hooks:no_hooks
      ~parent
      ~leaf
      ~publication_state
      ~set_success_warnings:(fun (snapshot : snapshot) warnings ->
        { snapshot with settlement_warnings = snapshot.settlement_warnings @ warnings })
      (fun ~sw ~parent ~parent_stat ~warnings:_ ->
        let* lock =
          match open_lock ~sw ~secure_random ~parent ~leaf with
          | Ok lock -> Ok lock
          | Error error -> Error (failure error)
        in
        let* snapshot =
          match read_current ~sw ~parent ~parent_stat ~leaf ~lock with
          | Ok snapshot -> Ok snapshot
          | Error error -> Error (failure error)
        in
        Ok snapshot)

let compare_and_swap_internal ~hooks ~secure_random ~parent ~leaf ~expected ~row =
  match validate_leaf leaf, validate_row row with
  | Error error, _ | _, Error error -> Error (failure error)
  | Ok (), Ok () ->
    let publication_state = ref Before_publication in
    run_transaction
      ~hooks
      ~parent
      ~leaf
      ~publication_state
      ~set_success_warnings:(fun publication warnings ->
        { publication with
          settlement_warnings = publication.settlement_warnings @ warnings
        })
      (fun ~sw ~parent ~parent_stat ~warnings ->
        let fail error = Error (failure_for_effect !publication_state error) in
        let* lock =
          match open_lock ~sw ~secure_random ~parent ~leaf with
          | Ok lock -> Ok lock
          | Error error -> fail error
        in
        invoke_hook Acquire_cross_process_lock hooks.after_lock_acquired;
        let* current =
          match read_current ~sw ~parent ~parent_stat ~leaf ~lock with
          | Ok current -> Ok current
          | Error error -> fail error
        in
        if not (cursor_equal expected current.cursor)
        then Error (failure (Conflict current))
        else
          let payload = row ^ "\n" in
          let indeterminate =
            { expected_cursor = expected
            ; intended_sha256 = sha256 payload
            ; intended_length = Int64.of_int (String.length payload)
            ; observed = None
            }
          in
          let* stage_path, stage_file =
            match create_stage ~sw ~secure_random ~parent 32 with
            | Ok stage -> Ok stage
            | Error error -> fail error
          in
          let cleanup_stage = ref true in
          let stage_identity = ref None in
          (* fun-protect-finally-ok: identity-checked stage cleanup must run
             while the protected Eio switch is alive; cleanup failures are
             caught and retained as settlement warnings. *)
          Fun.protect
            ~finally:(fun () ->
              if !cleanup_stage
              then
                try
                  invoke_hook Cleanup_stage hooks.before_stage_cleanup;
                  (match !stage_identity with
                   | None ->
                     warnings :=
                       Cleanup_failed
                         { operation = Cleanup_stage
                         ; detail = "stage identity unavailable; unknown path preserved"
                         }
                       :: !warnings
                   | Some opened_stat ->
                     (match
                        verify_path_binding
                          ~path:stage_path
                          ~opened_stat
                          ~what:"stage"
                          ~corrupt:(fun _detail ->
                            Io_error
                              { operation = Cleanup_stage
                              ; detail = "stage binding changed"
                              })
                      with
                      | Ok () -> Eio.Path.unlink stage_path
                      | Error _ ->
                        warnings :=
                          Cleanup_failed
                            { operation = Cleanup_stage
                            ; detail = "stage path no longer names created inode; preserved"
                            }
                          :: !warnings))
                with
                | Eio.Cancel.Cancelled _ as exn -> raise exn
                | exn ->
                  let raw_backtrace = Printexc.get_raw_backtrace () in
                  reraise_fatal exn raw_backtrace;
                  warnings :=
                    Cleanup_failed (diagnostic_of_exception Cleanup_stage exn) :: !warnings)
            (fun () ->
              let* initial_stage_stat =
                match protect_io Create_stage (fun () -> Eio.File.stat stage_file) with
                | Ok stat -> Ok stat
                | Error error -> fail error
              in
              stage_identity := Some initial_stage_stat;
              let* stage_stat =
                match write_stage ~path:stage_path stage_file payload with
                | Ok stat -> Ok stat
                | Error error -> fail error
              in
              stage_identity := Some stage_stat;
              let* () =
                match protect_io Close_stage (fun () -> Eio.Flow.close stage_file) with
                | Ok () -> Ok ()
                | Error error -> fail error
              in
              let* () =
                match
                  protect_result Revalidate (fun () ->
                    verify_path_binding
                      ~path:stage_path
                      ~opened_stat:stage_stat
                      ~what:"stage"
                      ~corrupt:(fun detail -> Io_error { operation = Revalidate; detail }))
                with
                | Ok () -> Ok ()
                | Error error -> fail error
              in
              let* revalidated =
                match read_current ~sw ~parent ~parent_stat ~leaf ~lock with
                | Ok current -> Ok current
                | Error error -> fail error
              in
              if not (cursor_equal expected revalidated.cursor)
              then Error (failure (Conflict revalidated))
              else (
                invoke_hook Revalidate hooks.before_rename;
                let* () =
                  match protect_result Revalidate (fun () -> verify_lock_binding lock) with
                  | Ok () -> Ok ()
                  | Error error -> fail error
                in
                let target_path = Eio.Path.(parent / leaf) in
                let* () =
                  match protect_io Rename_head (fun () -> Eio.Path.rename stage_path target_path) with
                  | Ok () -> Ok ()
                  | Error error -> fail error
                in
                cleanup_stage := false;
                publication_state := Renamed indeterminate;
                invoke_hook Rename_head hooks.after_rename;
                let* () =
                  match sync_parent parent with
                  | Ok () -> Ok ()
                  | Error error -> fail error
                in
                invoke_hook Sync_parent hooks.after_parent_sync;
                let* published =
                  match read_current ~sw ~parent ~parent_stat ~leaf ~lock with
                  | Ok published -> Ok published
                  | Error error -> fail error
                in
                publication_state :=
                  Renamed { indeterminate with observed = Some published.cursor };
                match published.row, published.cursor.target with
                | Some observed_row, Some observed_target
                  when String.equal observed_row row
                       && String.equal observed_target.sha256 indeterminate.intended_sha256
                       && Int64.equal observed_target.length indeterminate.intended_length ->
                  let evidence =
                    { expected_cursor = expected
                    ; intended_sha256 = indeterminate.intended_sha256
                    ; intended_length = indeterminate.intended_length
                    ; published_cursor = published.cursor
                    }
                  in
                  publication_state := Durable evidence;
                  invoke_hook Verify_publication hooks.after_verified;
                  Ok { evidence; settlement_warnings = [] }
                | _ -> fail (Corrupt_head "published HEAD does not match the staged row"))))

let compare_and_swap ~secure_random ~parent ~leaf ~expected ~row =
  compare_and_swap_internal ~hooks:no_hooks ~secure_random ~parent ~leaf ~expected ~row

module For_testing = struct
  type nonrec hooks = hooks

  let hooks
      ?(after_lock_acquired = fun () -> ())
      ?(before_rename = fun () -> ())
      ?(after_rename = fun () -> ())
      ?(after_parent_sync = fun () -> ())
      ?(after_verified = fun () -> ())
      ?(before_stage_cleanup = fun () -> ())
      ?(on_resource_settlement = fun () -> ())
      ()
    =
    { after_lock_acquired
    ; before_rename
    ; after_rename
    ; after_parent_sync
    ; after_verified
    ; before_stage_cleanup
    ; on_resource_settlement
    }

  let compare_and_swap hooks ~secure_random ~parent ~leaf ~expected ~row =
    compare_and_swap_internal ~hooks ~secure_random ~parent ~leaf ~expected ~row
end
