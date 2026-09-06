type operation =
  | Pin_parent
  | Open_parent_descriptor
  | Open_leaf
  | Inspect_opened
  | Allocate
  | Read_exact
  | Inspect_after_read
  | Close_leaf
  | Settle_parent_resources
  | Observe_parent_cancellation

type diagnostic =
  { operation : operation
  ; detail : string
  }

type settlement_warning =
  | Close_failed of diagnostic
  | Settle_resources of diagnostic

type error =
  | Invalid_leaf of string
  | Invalid_length_bounds of
      { expected_length : int64
      ; max_length : int64
      }
  | Length_not_representable of int64
  | Cancelled of diagnostic
  | Parent_descriptor_unavailable
  | Missing
  | Symbolic_link
  | Not_regular of Unix.file_kind
  | Unsafe_link_count of int
  | Unsafe_mode of int
  | Length_exceeds_max of
      { max_length : int64
      ; observed_length : int64
      }
  | Length_mismatch of
      { expected_length : int64
      ; observed_length : int64
      }
  | Changed_during_read
  | Io_error of diagnostic

type observation =
  { bytes : string
  ; length : int64
  ; settlement_warnings : settlement_warning list
  }

let observation_bytes observation = observation.bytes
let observation_length observation = observation.length

let observation_settlement_warnings observation =
  observation.settlement_warnings

type failure =
  { error : error
  ; settlement_warnings : settlement_warning list
  }

type hooks =
  { before_open : unit -> unit
  ; after_open_stat : unit -> unit
  ; before_allocate : unit -> unit
  ; after_exact_read : unit -> unit
  ; on_close : unit -> unit
  ; on_settle_resources : (unit -> unit) option
  }

let no_hook () = ()

let production_hooks =
  { before_open = no_hook
  ; after_open_stat = no_hook
  ; before_allocate = no_hook
  ; after_exact_read = no_hook
  ; on_close = no_hook
  ; on_settle_resources = None
  }

external openat_nofollow_ro_nonblock :
  Unix.file_descr -> string -> Unix.file_descr
  = "caml_masc_fs_compat_openat_nofollow_ro_nonblock"

let diagnostic operation exn =
  { operation; detail = Printexc.to_string exn }

let is_fatal = function
  | Out_of_memory | Stack_overflow | Sys.Break -> true
  | _ -> false

let reraise_if_fatal ~backtrace exn =
  if is_fatal exn then
    Printexc.raise_with_backtrace exn backtrace

let error_of_exception operation = function
  | (Out_of_memory | Stack_overflow | Sys.Break) as exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      Printexc.raise_with_backtrace exn backtrace
  | Eio.Cancel.Cancelled _ as exn ->
      Cancelled (diagnostic operation exn)
  | exn ->
      Io_error (diagnostic operation exn)

let failure error =
  Error { error; settlement_warnings = [] }

let run_hook operation hook =
  try
    hook ();
    Ok ()
  with
  | exn ->
      Error (error_of_exception operation exn)

let validate ~leaf ~expected_length ~max_length =
  if
    String.index_opt leaf '\000' <> None
    || Option.is_none (Capability_leaf.of_string leaf)
  then
    Error (Invalid_leaf leaf)
  else if
    Int64.compare expected_length 0L < 0
    || Int64.compare max_length 0L < 0
    || Int64.compare expected_length max_length > 0
  then
    Error (Invalid_length_bounds { expected_length; max_length })
  else
    let largest_representable =
      Int64.of_int Sys.max_string_length
    in
    if Int64.compare expected_length largest_representable > 0 then
      Error (Length_not_representable expected_length)
    else
      Ok (Int64.to_int expected_length)

let open_leaf parent_fd leaf =
  try
    Ok
      (Eio_unix.Fd.use_exn
         "capability exact read parent"
         parent_fd
         (fun raw_parent_fd ->
            Eio_unix.run_in_systhread ~label:"fs-compat-exact-open" (fun () ->
              openat_nofollow_ro_nonblock raw_parent_fd leaf)))
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Missing
  | Unix.Unix_error (Unix.ELOOP, _, _) -> Error Symbolic_link
  | exn -> Error (error_of_exception Open_leaf exn)

let fstat operation fd =
  try
    Ok
      (Eio_unix.run_in_systhread ~label:"fs-compat-exact-fstat" (fun () ->
         Unix.LargeFile.fstat fd))
  with
  | exn -> Error (error_of_exception operation exn)

type exact_read =
  | Short_read
  | Exact_eof
  | Extra_byte

let read_exact_and_eof fd bytes =
  try
    Ok
      (Eio_unix.run_in_systhread ~label:"fs-compat-exact-read" (fun () ->
         let expected = Bytes.length bytes in
         let rec fill offset =
           if offset = expected then
             true
           else
             try
               match Unix.read fd bytes offset (expected - offset) with
               | 0 -> false
               | count -> fill (offset + count)
             with
             | Unix.Unix_error (Unix.EINTR, _, _) -> fill offset
         in
         if not (fill 0) then
           Short_read
         else
           let probe = Bytes.create 1 in
           let rec probe_eof () =
             try
               match Unix.read fd probe 0 1 with
               | 0 -> Exact_eof
               | _ -> Extra_byte
             with
             | Unix.Unix_error (Unix.EINTR, _, _) -> probe_eof ()
           in
           probe_eof ()))
  with
  | exn -> Error (error_of_exception Read_exact exn)

let same_file left right =
  left.Unix.LargeFile.st_dev = right.Unix.LargeFile.st_dev
  && left.st_ino = right.st_ino
  && left.st_kind = right.st_kind
  && left.st_nlink = right.st_nlink
  && left.st_perm = right.st_perm
  && Int64.equal left.st_size right.st_size

let inspect_initial ~expected_length ~max_length stat =
  if stat.Unix.LargeFile.st_kind <> Unix.S_REG then
    Error (Not_regular stat.st_kind)
  else if stat.st_nlink <> 1 then
    Error (Unsafe_link_count stat.st_nlink)
  else if stat.st_perm <> 0o600 then
    Error (Unsafe_mode stat.st_perm)
  else if Int64.compare stat.st_size max_length > 0 then
    Error
      (Length_exceeds_max
         { max_length; observed_length = stat.st_size })
  else if not (Int64.equal stat.st_size expected_length) then
    Error
      (Length_mismatch
         { expected_length; observed_length = stat.st_size })
  else
    Ok ()

type settlement_call =
  | Settled
  | Settlement_warning of settlement_warning
  | Settlement_fatal of exn * Printexc.raw_backtrace

let capture_close_call call =
  try
    call ();
    Settled
  with
  | exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      if is_fatal exn then
        Settlement_fatal (exn, backtrace)
      else
        Settlement_warning
          (Close_failed (diagnostic Close_leaf exn))

let close_leaf hooks fd =
  let hook_outcome = capture_close_call hooks.on_close in
  let close_outcome = capture_close_call (fun () -> Unix.close fd) in
  match hook_outcome, close_outcome with
  | Settlement_fatal (exn, backtrace), _
  | _, Settlement_fatal (exn, backtrace) ->
      Printexc.raise_with_backtrace exn backtrace
  | (Settled | Settlement_warning _),
    (Settled | Settlement_warning _) ->
      let warnings = function
        | Settlement_warning warning -> [warning]
        | Settled | Settlement_fatal _ -> []
      in
      warnings hook_outcome @ warnings close_outcome

let read_opened
    ~hooks
    ~fd
    ~expected_length
    ~max_length
    ~expected_length_int
  =
  match fstat Inspect_opened fd with
  | Error error -> Error error
  | Ok initial_stat ->
      (match inspect_initial ~expected_length ~max_length initial_stat with
       | Error error -> Error error
       | Ok () ->
           (match run_hook Inspect_opened hooks.after_open_stat with
            | Error error -> Error error
            | Ok () ->
                (match run_hook Allocate hooks.before_allocate with
                 | Error error -> Error error
                 | Ok () ->
                     let bytes = Bytes.create expected_length_int in
                     (match read_exact_and_eof fd bytes with
                      | Error error -> Error error
                      | Ok (Short_read | Extra_byte) ->
                          Error Changed_during_read
                      | Ok Exact_eof ->
                          (match
                             run_hook
                               Read_exact
                               hooks.after_exact_read
                           with
                           | Error error -> Error error
                           | Ok () ->
                               (match fstat Inspect_after_read fd with
                                | Error error -> Error error
                                | Ok final_stat ->
                                    if
                                      not
                                        (same_file
                                           initial_stat
                                           final_stat)
                                    then
                                      Error Changed_during_read
                                    else
                                      Ok (Bytes.unsafe_to_string bytes)))))))

let attach_settlement_warnings outcome settlement_warnings =
  match outcome with
  | Ok bytes ->
      Ok
        { bytes
        ; length = Int64.of_int (String.length bytes)
        ; settlement_warnings
        }
  | Error error ->
      Error { error; settlement_warnings }

let append_settlement_warning
    (outcome : (observation, failure) result)
    warning
  =
  match outcome with
  | Ok observation ->
      Ok
        { observation with
          settlement_warnings =
            observation.settlement_warnings @ [warning]
        }
  | Error failure ->
      Error
        { failure with
          settlement_warnings =
            failure.settlement_warnings @ [warning]
        }

let diagnostic_of_raised operation (raised : Eio_resource_scope.raised) =
  diagnostic operation raised.exception_

let diagnostic_of_cancelled
    operation
    (cancelled : Eio_resource_scope.cancelled)
  =
  diagnostic
    operation
    (Eio.Cancel.Cancelled cancelled.reason)

let reraise_raised_if_fatal (raised : Eio_resource_scope.raised) =
  reraise_if_fatal
    ~backtrace:raised.backtrace
    raised.exception_

let outcome_of_resource_scope scope =
  (match scope.Eio_resource_scope.callback with
   | Some (Eio_resource_scope.Raised raised) ->
       reraise_raised_if_fatal raised
   | Some
       ( Eio_resource_scope.Returned _
       | Eio_resource_scope.Cancelled _ )
   | None ->
       ());
  Option.iter reraise_raised_if_fatal scope.scope_failure;
  let callback_outcome =
    match scope.Eio_resource_scope.callback with
    | Some (Eio_resource_scope.Returned outcome) -> outcome
    | Some (Eio_resource_scope.Raised raised) ->
        failure
          (error_of_exception
             Settle_parent_resources
             raised.exception_)
    | Some (Eio_resource_scope.Cancelled cancelled) ->
        failure
          (Cancelled
             (diagnostic_of_cancelled
                Settle_parent_resources
                cancelled))
    | None ->
        (match scope.parent_cancellation, scope.scope_failure with
         | Some cancelled, _ ->
             failure
               (Cancelled
                  (diagnostic_of_cancelled
                     Settle_parent_resources
                     cancelled))
         | None, Some raised ->
             failure
               (error_of_exception
                  Settle_parent_resources
                  raised.exception_)
         | None, None ->
             failure
               (Io_error
                  (diagnostic
                     Settle_parent_resources
                     (Failure
                        "resource scope callback did not run"))))
  in
  match scope.callback with
  | None -> callback_outcome
  | Some _ ->
      let with_scope_failure =
        match scope.scope_failure with
        | None -> callback_outcome
        | Some raised ->
            append_settlement_warning
              callback_outcome
              (Settle_resources
                 (diagnostic_of_raised
                    Settle_parent_resources
                    raised))
      in
      (match scope.parent_cancellation with
       | None -> with_scope_failure
       | Some cancelled ->
           append_settlement_warning
             with_scope_failure
             (Settle_resources
                (diagnostic_of_cancelled
                   Observe_parent_cancellation
                   cancelled)))

let read_with_hooks
    ~hooks
    ~parent
    ~leaf
    ~expected_length
    ~max_length
  =
  Eio.Fiber.check ();
  match validate ~leaf ~expected_length ~max_length with
  | Error error -> failure error
  | Ok expected_length_int ->
      let scope =
        Eio_resource_scope.run_resource_only (fun sw ->
           Option.iter
             (Eio.Switch.on_release sw)
             hooks.on_settle_resources;
           match
             try Ok (Eio.Path.open_dir ~sw parent) with
             | exn -> Error (error_of_exception Pin_parent exn)
           with
           | Error error -> failure error
           | Ok exact_parent ->
               (match
                  try
                    Ok
                      (Eio.Path.open_in
                         ~sw
                         Eio.Path.(exact_parent / "."))
                  with
                  | exn ->
                      Error
                        (error_of_exception
                           Open_parent_descriptor
                           exn)
                with
                | Error error -> failure error
                | Ok parent_resource ->
                    (match Eio_unix.Resource.fd_opt parent_resource with
                     | None -> failure Parent_descriptor_unavailable
                     | Some parent_fd ->
                         (match
                            run_hook Open_leaf hooks.before_open
                          with
                          | Error error -> failure error
                          | Ok () ->
                              Eio.Cancel.protect (fun () ->
                                match open_leaf parent_fd leaf with
                                | Error error -> failure error
                                | Ok fd ->
                                    let outcome =
                                      try
                                        read_opened
                                          ~hooks
                                          ~fd
                                          ~expected_length
                                          ~max_length
                                          ~expected_length_int
                                      with
                                      | ( Out_of_memory
                                        | Stack_overflow
                                        | Sys.Break ) as exn ->
                                          let backtrace =
                                            Printexc.get_raw_backtrace ()
                                          in
                                          (try
                                             ignore
                                               (close_leaf hooks fd)
                                           with
                                           | _ -> ());
                                          Printexc.raise_with_backtrace
                                            exn
                                            backtrace
                                      | exn ->
                                          Error
                                            (error_of_exception
                                               Read_exact
                                               exn)
                                    in
                                    let settlement_warnings =
                                      close_leaf hooks fd
                                    in
                                    attach_settlement_warnings
                                      outcome
                                      settlement_warnings)))))
      in
      outcome_of_resource_scope scope

let read ~parent ~leaf ~expected_length ~max_length =
  read_with_hooks
    ~hooks:production_hooks
    ~parent
    ~leaf
    ~expected_length
    ~max_length

module For_testing = struct
  type nonrec hooks = hooks

  let hooks
      ?(before_open = no_hook)
      ?(after_open_stat = no_hook)
      ?(before_allocate = no_hook)
      ?(after_exact_read = no_hook)
      ?(on_close = no_hook)
      ?on_settle_resources
      ()
    =
    { before_open
    ; after_open_stat
    ; before_allocate
    ; after_exact_read
    ; on_close
    ; on_settle_resources
    }

  let read = read_with_hooks
end
