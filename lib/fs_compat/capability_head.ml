type lock_state =
  | Virgin
  | Active

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
  ; lock_state : lock_state
  ; target : target_fingerprint option
  }

type snapshot =
  { row : string option
  ; cursor : cursor
  ; settlement_warnings : string list
  }

let snapshot_row snapshot = snapshot.row
let snapshot_cursor snapshot = snapshot.cursor
let snapshot_settlement_warnings snapshot = snapshot.settlement_warnings

type io_error =
  { operation : string
  ; detail : string
  }

type error =
  | Invalid_leaf of string
  | Invalid_row of string
  | Busy
  | Conflict of snapshot
  | Corrupt_lock of string
  | Corrupt_head of string
  | Unsupported of string
  | Io_error of io_error

type publication_indeterminate =
  { intended_sha256 : string
  ; intended_length : int64
  ; observed : cursor option
  }

type target_effect =
  | Unchanged
  | Publication_indeterminate of publication_indeterminate

type failure =
  { error : error
  ; target_effect : target_effect
  ; settlement_warnings : string list
  }

type publication =
  { cursor : cursor
  ; settlement_warnings : string list
  }

let publication_cursor publication = publication.cursor
let publication_settlement_warnings publication = publication.settlement_warnings

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

  type token = Key.t

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

type lock_handle =
  { file : Eio.File.rw_ty Eio.Resource.t
  ; path : Eio.Fs.dir_ty Eio.Path.t
  ; stat : Eio.File.Stat.t
  ; epoch : string
  ; state : lock_state
  }

type transaction_effect =
  | Before_publication
  | Renamed of publication_indeterminate
  | Durable of cursor

let lock_magic = "MASC-CAPABILITY-HEAD-LOCK-v1"
let max_lock_marker_bytes = 256
let stage_counter = Atomic.make 0

let sha256 value = Digestif.SHA256.(to_hex (digest_string value))

let exception_detail exn =
  Printexc.to_string exn

let io_error operation exn =
  Io_error { operation; detail = exception_detail exn }

let failure ?(target_effect = Unchanged) error =
  { error; target_effect; settlement_warnings = [] }

let target_effect_of_transaction = function
  | Before_publication -> Unchanged
  | Renamed evidence -> Publication_indeterminate evidence
  | Durable _ -> Unchanged

let failure_for_effect effect error =
  failure ~target_effect:(target_effect_of_transaction effect) error

let validate_leaf leaf =
  if String.equal leaf ""
     || String.equal leaf "."
     || String.equal leaf ".."
     || String.exists (fun char -> Char.equal char '/' || Char.equal char '\000') leaf
  then Error (Invalid_leaf leaf)
  else Ok ()

let validate_row row =
  if String.equal row ""
  then Error (Invalid_row "HEAD row must be non-empty")
  else if String.exists (fun char -> Char.equal char '\n' || Char.equal char '\r') row
  then Error (Invalid_row "HEAD row must not contain CR or LF")
  else Ok ()

let lock_state_name = function
  | Virgin -> "virgin"
  | Active -> "active"

let lock_leaf leaf =
  ".masc-capability-head-" ^ sha256 leaf ^ ".lock"

let is_lower_hex value =
  String.length value = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       value

let marker ~state ~epoch =
  Printf.sprintf "%s %s %s\n" lock_magic (lock_state_name state) epoch

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
      | [ magic; state; epoch ] when String.equal magic lock_magic && is_lower_hex epoch ->
        (match state with
         | "virgin" -> Ok (Virgin, epoch)
         | "active" -> Ok (Active, epoch)
         | _ -> Error (Corrupt_lock "stable lock marker has an unknown state"))
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
  else if stat.perm land 0o777 <> 0o600
  then Error (corrupt (what ^ " must have mode 0600"))
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

let read_open_file ~max_bytes ~what ~corrupt file =
  let before = Eio.File.stat file in
  let size64 = Optint.Int63.to_int64 before.size in
  if Int64.compare size64 0L < 0
  then Error (corrupt (what ^ " has a negative size"))
  else if Int64.compare size64 (Int64.of_int max_bytes) > 0
  then Error (corrupt (what ^ " exceeds its byte bound"))
  else
    let size = Int64.to_int size64 in
    ignore (Eio.File.seek file (Optint.Int63.of_int 0) `Set);
    let value = Eio.Flow.read_all ~max_size:(max_bytes + 1) file in
    let after = Eio.File.stat file in
    if not (same_open_file before after)
    then Error (corrupt (what ^ " changed while it was being read"))
    else if String.length value <> size
    then Error (corrupt (what ^ " size changed while it was being read"))
    else Ok (value, after)

let write_exact file value =
  Eio.File.truncate file (Optint.Int63.of_int 0);
  ignore (Eio.File.seek file (Optint.Int63.of_int 0) `Set);
  Eio.Flow.copy_string value file;
  Eio.File.truncate file (Optint.Int63.of_int (String.length value));
  Eio.File.sync file

let sync_parent parent =
  let resource, _relative = parent in
  match Eio_unix.Resource.fd_opt resource with
  | None -> Error (Unsupported "parent directory capability has no Unix file descriptor")
  | Some fd ->
    (try
       Eio_unix.Fd.use_exn "capability_head.sync_parent" fd (fun raw_fd ->
         Eio_unix.run_in_systhread
           ~label:"capability_head.sync_parent"
           (fun () -> Unix.fsync raw_fd));
       Ok ()
     with
     | exn -> Error (io_error "sync_parent" exn))

let try_lock file =
  match Eio_unix.Resource.fd_opt file with
  | None -> Error (Unsupported "stable lock has no Unix file descriptor")
  | Some fd ->
    (try
       Eio_unix.Fd.use_exn "capability_head.try_lock" fd (fun raw_fd ->
         Eio_unix.run_in_systhread
           ~label:"capability_head.try_lock"
           (fun () ->
             ignore (Unix.lseek raw_fd 0 Unix.SEEK_SET);
             Unix.lockf raw_fd Unix.F_TLOCK 0));
       Ok ()
     with
     | Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> Error Busy
     | exn -> Error (io_error "try_lock" exn))

let epoch_for_lock ~parent_stat ~leaf (lock_stat : Eio.File.Stat.t) =
  sha256
    (Printf.sprintf
       "%Ld\000%Ld\000%s\000%Ld\000%Ld\000%.17g\000%.17g"
       parent_stat.Eio.File.Stat.dev
       parent_stat.ino
       leaf
       lock_stat.dev
       lock_stat.ino
       lock_stat.ctime
       lock_stat.mtime)

let open_lock ~sw ~parent ~parent_stat ~leaf =
  let target_path = Eio.Path.(parent / leaf) in
  let path = Eio.Path.(parent / lock_leaf leaf) in
  match Eio.Path.kind ~follow:false path with
  | (`Not_found | `Regular_file) ->
    let file = Eio.Path.open_out ~sw ~create:(`If_missing 0o600) path in
    (match try_lock file with
     | Error error -> Error error
     | Ok () ->
       let opened_stat = Eio.File.stat file in
       (match
          validate_private_regular
            ~what:"stable lock"
            ~corrupt:(fun detail -> Corrupt_lock detail)
            opened_stat
        with
        | Error error -> Error error
        | Ok () ->
          (match
             verify_path_binding
               ~path
               ~opened_stat
               ~what:"stable lock"
               ~corrupt:(fun detail -> Corrupt_lock detail)
           with
           | Error error -> Error error
           | Ok () ->
             (match
                read_open_file
                  ~max_bytes:max_lock_marker_bytes
                  ~what:"stable lock marker"
                  ~corrupt:(fun detail -> Corrupt_lock detail)
                  file
              with
              | Error error -> Error error
              | Ok ("", _) ->
                (match Eio.Path.kind ~follow:false target_path with
                 | `Not_found ->
                   Eio.File.sync file;
                   (match sync_parent parent with
                    | Error error -> Error error
                    | Ok () ->
                      let epoch = epoch_for_lock ~parent_stat ~leaf opened_stat in
                      write_exact file (marker ~state:Virgin ~epoch);
                      Ok { file; path; stat = opened_stat; epoch; state = Virgin })
                 | _ ->
                   Error
                     (Corrupt_lock
                        "empty stable lock exists beside a non-empty HEAD namespace"))
              | Ok (value, _) ->
                (match parse_marker value with
                 | Error error -> Error error
                 | Ok (state, epoch) ->
                   Ok { file; path; stat = opened_stat; epoch; state })))))
  | `Symbolic_link -> Error (Corrupt_lock "stable lock path is a symbolic link")
  | _ -> Error (Corrupt_lock "stable lock path is not a regular file")

let parse_head_payload payload =
  let length = String.length payload in
  if length < 2
  then Error (Corrupt_head "HEAD must contain one non-empty LF-terminated row")
  else if not (Char.equal payload.[length - 1] '\n')
  then Error (Corrupt_head "HEAD is not LF-terminated")
  else
    let row = String.sub payload 0 (length - 1) in
    if String.exists (fun char -> Char.equal char '\n' || Char.equal char '\r') row
    then Error (Corrupt_head "HEAD contains multiple rows or CR")
    else Ok row

let read_target ~sw ~parent ~leaf =
  let path = Eio.Path.(parent / leaf) in
  match Eio.Path.kind ~follow:false path with
  | `Not_found -> Ok None
  | `Regular_file ->
    let file = Eio.Path.open_in ~sw path in
    let opened_stat = Eio.File.stat file in
    (match
       validate_private_regular
         ~what:"HEAD"
         ~corrupt:(fun detail -> Corrupt_head detail)
         opened_stat
     with
     | Error error -> Error error
     | Ok () ->
       (match
          verify_path_binding
            ~path
            ~opened_stat
            ~what:"HEAD"
            ~corrupt:(fun detail -> Corrupt_head detail)
        with
        | Error error -> Error error
        | Ok () ->
          let max_bytes = Sys.max_string_length - 1 in
          (match
             read_open_file
               ~max_bytes
               ~what:"HEAD"
               ~corrupt:(fun detail -> Corrupt_head detail)
               file
           with
           | Error error -> Error error
           | Ok (payload, final_stat) ->
             (match
                verify_path_binding
                  ~path
                  ~opened_stat:final_stat
                  ~what:"HEAD"
                  ~corrupt:(fun detail -> Corrupt_head detail)
              with
              | Error error -> Error error
              | Ok () ->
                (match parse_head_payload payload with
                 | Error error -> Error error
                 | Ok row ->
                   let fingerprint =
                     { dev = final_stat.dev
                     ; ino = final_stat.ino
                     ; length = Int64.of_int (String.length payload)
                     ; sha256 = sha256 payload
                     }
                   in
                   Ok (Some (row, fingerprint)))))))
  | `Symbolic_link -> Error (Corrupt_head "HEAD path is a symbolic link")
  | _ -> Error (Corrupt_head "HEAD path is not a regular file")

let verify_lock_binding lock =
  verify_path_binding
    ~path:lock.path
    ~opened_stat:lock.stat
    ~what:"stable lock"
    ~corrupt:(fun detail -> Corrupt_lock detail)

let activate_lock lock =
  match verify_lock_binding lock with
  | Error error -> Error error
  | Ok () ->
    write_exact lock.file (marker ~state:Active ~epoch:lock.epoch);
    Ok { lock with state = Active }

let make_cursor ~parent_stat ~leaf ~lock ~target =
  { parent_dev = parent_stat.Eio.File.Stat.dev
  ; parent_ino = parent_stat.ino
  ; leaf
  ; lock_dev = lock.stat.dev
  ; lock_ino = lock.stat.ino
  ; lock_epoch = lock.epoch
  ; lock_state = lock.state
  ; target
  }

let read_current ~sw ~parent ~parent_stat ~leaf ~lock =
  match read_target ~sw ~parent ~leaf with
  | Error error -> Error error
  | Ok None ->
    (match lock.state with
     | Active -> Error (Corrupt_head "an active stable lock has no HEAD")
     | Virgin ->
       let cursor = make_cursor ~parent_stat ~leaf ~lock ~target:None in
       Ok ({ row = None; cursor; settlement_warnings = [] }, lock))
  | Ok (Some (row, target)) ->
    (match lock.state with
     | Active ->
       let cursor = make_cursor ~parent_stat ~leaf ~lock ~target:(Some target) in
       Ok ({ row = Some row; cursor; settlement_warnings = [] }, lock)
     | Virgin ->
       (match sync_parent parent with
        | Error error -> Error error
        | Ok () ->
          (match activate_lock lock with
           | Error error -> Error error
           | Ok active_lock ->
             let cursor =
               make_cursor ~parent_stat ~leaf ~lock:active_lock ~target:(Some target)
             in
             Ok ({ row = Some row; cursor; settlement_warnings = [] }, active_lock))))

let cursor_equal left right =
  left = right

let stage_leaf ~leaf ~payload =
  let serial = Atomic.fetch_and_add stage_counter 1 in
  let digest = sha256 (Printf.sprintf "%s\000%s\000%d" leaf payload serial) in
  ".masc-capability-head-stage-" ^ String.sub digest 0 32

let rec create_stage ~sw ~parent ~leaf ~payload attempts =
  if attempts = 0
  then Error (Io_error { operation = "create_stage"; detail = "stage namespace exhausted" })
  else
    let stage_leaf = stage_leaf ~leaf ~payload in
    let path = Eio.Path.(parent / stage_leaf) in
    try
      let file = Eio.Path.open_out ~sw ~create:(`Exclusive 0o600) path in
      Ok (path, file)
    with
    | Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) ->
      create_stage ~sw ~parent ~leaf ~payload (attempts - 1)

let write_stage ~path file payload =
  Eio.Flow.copy_string payload file;
  Eio.File.sync file;
  let opened_stat = Eio.File.stat file in
  match
    validate_private_regular
      ~what:"stage"
      ~corrupt:(fun detail -> Io_error { operation = "write_stage"; detail })
      opened_stat
  with
  | Error error -> Error error
  | Ok () ->
    if
      not
        (Int64.equal
           (Optint.Int63.to_int64 opened_stat.size)
           (Int64.of_int (String.length payload)))
    then Error (Io_error { operation = "write_stage"; detail = "stage size mismatch" })
    else
      verify_path_binding
        ~path
        ~opened_stat
        ~what:"stage"
        ~corrupt:(fun detail -> Io_error { operation = "write_stage"; detail })

let add_warning warnings operation exn =
  warnings := (operation ^ ": " ^ exception_detail exn) :: !warnings

let normalize_result ~warnings ~set_success_warnings = function
  | Ok value -> Ok (set_success_warnings value warnings)
  | Error failure ->
    Error
      { failure with
        settlement_warnings = failure.settlement_warnings @ warnings
      }

let run_transaction ~parent ~leaf ~effect ~set_success_warnings transaction =
  Eio.Fiber.check ();
  let token = ref None in
  let completed = ref None in
  let warnings = ref [] in
  Fun.protect
    ~finally:(fun () -> Option.iter Lease.release !token)
    (fun () ->
      try
        Eio.Switch.run_protected (fun sw ->
          let exact_parent = Eio.Path.open_dir ~sw parent in
          let parent_stat = Eio.Path.stat ~follow:false exact_parent in
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
        when !effect = Before_publication && Option.is_none !completed ->
        raise exn
      | exn ->
        let close_warning = "resource settlement: " ^ exception_detail exn in
        (match !completed with
         | Some (Ok value) -> Ok (set_success_warnings value [ close_warning ])
         | Some (Error failure) ->
           Error
             { failure with
               settlement_warnings = failure.settlement_warnings @ [ close_warning ]
             }
         | None ->
           let error = io_error "capability_head_transaction" exn in
           Error
             { (failure_for_effect !effect error) with
               settlement_warnings = List.rev !warnings @ [ close_warning ]
             }))

let read ~parent ~leaf =
  match validate_leaf leaf with
  | Error error -> Error (failure error)
  | Ok () ->
    let effect = ref Before_publication in
    run_transaction
      ~parent
      ~leaf
      ~effect
      ~set_success_warnings:(fun snapshot warnings ->
        { snapshot with settlement_warnings = snapshot.settlement_warnings @ warnings })
      (fun ~sw ~parent ~parent_stat ~warnings:_ ->
        match open_lock ~sw ~parent ~parent_stat ~leaf with
        | Error error -> Error (failure_for_effect !effect error)
        | Ok lock ->
          (match read_current ~sw ~parent ~parent_stat ~leaf ~lock with
           | Error error -> Error (failure_for_effect !effect error)
           | Ok (snapshot, _lock) -> Ok snapshot))

let compare_and_swap ~parent ~leaf ~expected ~row =
  match validate_leaf leaf, validate_row row with
  | Error error, _ | _, Error error -> Error (failure error)
  | Ok (), Ok () ->
    let effect = ref Before_publication in
    run_transaction
      ~parent
      ~leaf
      ~effect
      ~set_success_warnings:(fun publication warnings ->
        { publication with
          settlement_warnings = publication.settlement_warnings @ warnings
        })
      (fun ~sw ~parent ~parent_stat ~warnings ->
        match open_lock ~sw ~parent ~parent_stat ~leaf with
        | Error error -> Error (failure_for_effect !effect error)
        | Ok lock ->
          (match read_current ~sw ~parent ~parent_stat ~leaf ~lock with
           | Error error -> Error (failure_for_effect !effect error)
           | Ok (current, lock) ->
             if not (cursor_equal expected current.cursor)
             then Error (failure (Conflict current))
             else
               let payload = row ^ "\n" in
               let intended =
                 { intended_sha256 = sha256 payload
                 ; intended_length = Int64.of_int (String.length payload)
                 ; observed = None
                 }
               in
               (match create_stage ~sw ~parent ~leaf ~payload 32 with
                | Error error -> Error (failure_for_effect !effect error)
                | Ok (stage_path, stage_file) ->
                  let cleanup_stage = ref true in
                  Fun.protect
                    ~finally:(fun () ->
                      if !cleanup_stage
                      then
                        try Eio.Path.unlink stage_path with
                        | exn -> add_warning warnings "stage cleanup" exn)
                    (fun () ->
                      match write_stage ~path:stage_path stage_file payload with
                      | Error error -> Error (failure_for_effect !effect error)
                      | Ok () ->
                        (match read_current ~sw ~parent ~parent_stat ~leaf ~lock with
                         | Error error -> Error (failure_for_effect !effect error)
                         | Ok (revalidated, lock) ->
                           if not (cursor_equal expected revalidated.cursor)
                           then Error (failure (Conflict revalidated))
                           else
                             (match verify_lock_binding lock with
                              | Error error -> Error (failure_for_effect !effect error)
                              | Ok () ->
                                let target_path = Eio.Path.(parent / leaf) in
                                Eio.Path.rename stage_path target_path;
                                cleanup_stage := false;
                                effect := Renamed intended;
                                (match sync_parent parent with
                                 | Error error ->
                                   Error (failure_for_effect !effect error)
                                 | Ok () ->
                                   (match
                                      read_current
                                        ~sw
                                        ~parent
                                        ~parent_stat
                                        ~leaf
                                        ~lock
                                    with
                                    | Error error ->
                                      Error (failure_for_effect !effect error)
                                    | Ok (published, _active_lock) ->
                                      effect :=
                                        Renamed
                                          { intended with
                                            observed = Some published.cursor
                                          };
                                      (match published.row, published.cursor.target with
                                       | Some observed_row, Some observed_target
                                         when String.equal observed_row row
                                              && String.equal
                                                   observed_target.sha256
                                                   intended.intended_sha256
                                              && Int64.equal
                                                   observed_target.length
                                                   intended.intended_length ->
                                         effect := Durable published.cursor;
                                         Ok
                                           { cursor = published.cursor
                                           ; settlement_warnings = []
                                           }
                                       | _ ->
                                         Error
                                           (failure_for_effect
                                              !effect
                                              (Corrupt_head
                                                 "published HEAD does not match the staged row")))))))))))
