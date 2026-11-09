open Fs_compat_internal

type durable_append_operation =
  | Incomplete_tail_read
  | Incomplete_tail_truncate
  | Incomplete_tail_fsync
  | Write
  | Append_fsync
  | Rollback_truncate
  | Rollback_fsync

type durable_append_failure =
  | Unix_error of
      { operation : durable_append_operation
      ; error : Unix.error
      ; function_name : string
      ; argument : string
      }
  | No_write_progress

type durable_append_error =
  { append_failure : durable_append_failure
  ; rollback_failures : durable_append_failure list
  }

let durable_append_operation_to_string = function
  | Incomplete_tail_read -> "incomplete tail read"
  | Incomplete_tail_truncate -> "incomplete tail truncate"
  | Incomplete_tail_fsync -> "incomplete tail fsync"
  | Write -> "write"
  | Append_fsync -> "append fsync"
  | Rollback_truncate -> "rollback truncate"
  | Rollback_fsync -> "rollback fsync"
;;

let durable_append_failure_to_string = function
  | No_write_progress -> "write made no progress"
  | Unix_error { operation; error; function_name; argument } ->
    Printf.sprintf
      "%s failed: %s (function=%S argument=%S)"
      (durable_append_operation_to_string operation)
      (Unix.error_message error)
      function_name
      argument
;;

let durable_append_error_to_string { append_failure; rollback_failures } =
  let append = durable_append_failure_to_string append_failure in
  match rollback_failures with
  | [] -> Printf.sprintf "durable append failed and rollback succeeded: %s" append
  | failures ->
    Printf.sprintf
      "durable append failed: %s; rollback failed: %s"
      append
      (failures
       |> List.map durable_append_failure_to_string
       |> String.concat "; ")
;;

type durable_append_io_for_testing =
  { write : Unix.file_descr -> bytes -> int -> int -> int
  ; ftruncate : Unix.file_descr -> int -> unit
  ; fsync : Unix.file_descr -> unit
  }

let unix_failure ~operation error function_name argument =
  Unix_error { operation; error; function_name; argument }
;;

let rec run_unix_io ~operation f =
  match f () with
  | () -> Ok ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> run_unix_io ~operation f
  | exception Unix.Unix_error (error, function_name, argument) ->
    Error (unix_failure ~operation error function_name argument)
;;

let rollback_durable_append ~io ~fd ~original_length =
  let truncate_result =
    run_unix_io ~operation:Rollback_truncate (fun () ->
      io.ftruncate fd original_length)
  in
  let fsync_result =
    run_unix_io ~operation:Rollback_fsync (fun () -> io.fsync fd)
  in
  [ truncate_result; fsync_result ]
  |> List.filter_map (function
    | Ok () -> None
    | Error failure -> Some failure)
;;

let append_fd_durable ~io ~fd ~original_length suffix =
  let bytes = Bytes.of_string suffix in
  let append_result =
    match
      Fd_write_all.run
        ~length:(Bytes.length bytes)
        ~write:(fun ~offset ~length -> io.write fd bytes offset length)
    with
    | Error (Fd_write_all.No_progress _) -> Error No_write_progress
    | Error
        (Fd_write_all.Unix_error
          { bytes_written = _; error; function_name; argument }) ->
      Error (unix_failure ~operation:Write error function_name argument)
    | Error
        (Fd_write_all.Operation_failed
          { bytes_written = _; exception_; backtrace }) ->
      Printexc.raise_with_backtrace exception_ backtrace
    | Ok () -> run_unix_io ~operation:Append_fsync (fun () -> io.fsync fd)
  in
  match append_result with
  | Ok () -> Ok ()
  | Error append_failure ->
    let rollback_failures = rollback_durable_append ~io ~fd ~original_length in
    Error { append_failure; rollback_failures }
;;

let append_fd_durable_for_testing = append_fd_durable

let durable_append_unix_io =
  { write = Unix.write; ftruncate = Unix.ftruncate; fsync = Unix.fsync }
;;

let fsync_parent_directory dir =
  let fd = Unix.openfile dir [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () -> Unix.fsync fd)
;;

let rec lock_whole_file fd =
  match Unix.lockf fd Unix.F_LOCK 0 with
  | () -> ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> lock_whole_file fd
;;

let rec lock_whole_file_shared fd =
  match Unix.lockf fd Unix.F_RLOCK 0 with
  | () -> ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> lock_whole_file_shared fd
;;

type capability_append_operation_failure =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

type capability_append_failure =
  | Capability_append_posix_descriptor_unavailable
  | Capability_append_mutation_contended
  | Capability_append_operation_failed of capability_append_operation_failure

type capability_append_target_binding =
  | Capability_append_target_not_checked
  | Capability_append_target_verified
  | Capability_append_target_changed
  | Capability_append_target_check_failed of capability_append_operation_failure

type capability_append_outcome =
  { requested_bytes : int
  ; bytes_written : int
  ; write_failure : capability_append_failure option
  ; sync_failure : capability_append_operation_failure option
  ; target_binding : capability_append_target_binding
  }

type capability_append_open_error =
  | Capability_append_open_invalid_leaf of string
  | Capability_append_open_missing
  | Capability_append_open_failed of capability_append_operation_failure

type capability_append_file =
  { parent : Eio.Fs.dir_ty Eio.Path.t
  ; leaf : Capability_leaf.t
  ; resource : Eio.File.rw_ty Eio.Resource.t
  ; stat : Eio.File.Stat.t
  }

let capability_append_failure_to_string = function
  | Capability_append_posix_descriptor_unavailable ->
    "POSIX descriptor unavailable"
  | Capability_append_mutation_contended ->
    "append target identity is busy in another cooperative writer"
  | Capability_append_operation_failed { exception_; _ } ->
    Printexc.to_string exception_
;;

let capability_append_open_error_to_string = function
  | Capability_append_open_invalid_leaf leaf ->
    Printf.sprintf "invalid capability leaf %S" leaf
  | Capability_append_open_missing -> "capability append target is missing"
  | Capability_append_open_failed { exception_; _ } ->
    Printexc.to_string exception_
;;

let capability_append_operation_failure exception_ backtrace =
  { exception_; backtrace }
;;

let open_capability_append_file ~sw ~parent ~leaf =
  match Capability_leaf.of_string leaf with
  | None -> Error (Capability_append_open_invalid_leaf leaf)
  | Some leaf ->
    let leaf_name = Capability_leaf.to_string leaf in
    (try
       let resource =
         Eio.Path.open_out
           ~sw
           ~append:true
           ~create:`Never
           Eio.Path.(parent / leaf_name)
       in
       let stat = Eio.File.stat resource in
       Ok { parent; leaf; resource; stat }
     with
     | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
     | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
       Error Capability_append_open_missing
     | exception_ ->
       let backtrace = Printexc.get_raw_backtrace () in
       Error
         (Capability_append_open_failed
            (capability_append_operation_failure exception_ backtrace)))
;;

let capability_append_file_stat file = file.stat

let capability_append_outcome
      ~requested_bytes
      ?(bytes_written = 0)
      ?write_failure
      ?sync_failure
      ?(target_binding = Capability_append_target_not_checked)
      ()
  =
  { requested_bytes
  ; bytes_written
  ; write_failure
  ; sync_failure
  ; target_binding
  }
;;

type capability_append_io_for_testing =
  { write_substring : Unix.file_descr -> string -> int -> int -> int
  ; fsync : Unix.file_descr -> unit
  }

let append_fd_observed ~io ~fd content =
  let requested_bytes = String.length content in
  let bytes_written, write_failure =
    match
      Fd_write_all.run
        ~length:requested_bytes
        ~write:(fun ~offset ~length ->
          io.write_substring fd content offset length)
    with
    | Ok () -> requested_bytes, None
    | Error (Fd_write_all.No_progress { bytes_written }) ->
      ( bytes_written
      , Some
          (Capability_append_operation_failed
             (capability_append_operation_failure
                (Unix.Unix_error
                   (Unix.EIO, "write", "regular file accepted zero bytes"))
                (Printexc.get_callstack 0))) )
    | Error
        (Fd_write_all.Unix_error
          { bytes_written; error; function_name; argument }) ->
      ( bytes_written
      , Some
          (Capability_append_operation_failed
             (capability_append_operation_failure
                (Unix.Unix_error (error, function_name, argument))
                (Printexc.get_callstack 0))) )
    | Error
        (Fd_write_all.Operation_failed
          { bytes_written; exception_; backtrace }) ->
      ( bytes_written
      , Some
          (Capability_append_operation_failed
             (capability_append_operation_failure exception_ backtrace)) )
  in
  let sync_failure =
    if bytes_written > 0 || Option.is_none write_failure
    then
      let rec sync () =
        try
          io.fsync fd;
          None
        with
        | Unix.Unix_error (Unix.EINTR, _, _) -> sync ()
        | exception_ -> (* cancel-guard-ok: io.fsync is a Unix fsync, no Eio operation *)
          let backtrace = Printexc.get_raw_backtrace () in
          Some (capability_append_operation_failure exception_ backtrace)
      in
      sync ()
    else None
  in
  capability_append_outcome
    ~requested_bytes
    ~bytes_written
    ?write_failure
    ?sync_failure
    ()
;;

let capability_append_unix_io =
  { write_substring = Unix.write_substring; fsync = Unix.fsync }
;;

type append_target_observation =
  | Append_target_verified
  | Append_target_changed
  | Append_target_check_failed of capability_append_operation_failure

let append_target_binding ~parent ~leaf opened =
  try
    let lexical = Eio.Path.stat ~follow:false Eio.Path.(parent / leaf) in
    if
      opened.Eio.File.Stat.kind = `Regular_file
      && lexical.kind = `Regular_file
      && Int64.equal opened.dev lexical.dev
      && Int64.equal opened.ino lexical.ino
    then Append_target_verified
    else Append_target_changed
  with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Append_target_changed
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Append_target_check_failed
      (capability_append_operation_failure exception_ backtrace)
;;

let capability_append_target_binding_of_observation = function
  | Append_target_verified -> Capability_append_target_verified
  | Append_target_changed -> Capability_append_target_changed
  | Append_target_check_failed failure ->
    Capability_append_target_check_failed failure
;;

let append_capability_observed_with ~after_write file content =
  let { parent; leaf; resource; stat = opened_stat } = file in
  let requested_bytes = String.length content in
  let leaf_name = Capability_leaf.to_string leaf in
  if requested_bytes = 0
  then capability_append_outcome ~requested_bytes ()
  else
    let parent_stat =
      try Ok (Eio.Path.stat ~follow:true parent) with
      | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
      | exception_ ->
        let backtrace = Printexc.get_raw_backtrace () in
        Error (capability_append_operation_failure exception_ backtrace)
    in
    match parent_stat with
    | Error failure ->
      capability_append_outcome
        ~requested_bytes
        ~write_failure:(Capability_append_operation_failed failure)
        ~target_binding:(Capability_append_target_check_failed failure)
        ()
    | Ok parent_stat when parent_stat.kind <> `Directory ->
      let exception_ =
        Invalid_argument "append parent capability is not a directory"
      in
      let failure =
        capability_append_operation_failure
          exception_
          (Printexc.get_callstack 0)
      in
      capability_append_outcome
        ~requested_bytes
        ~write_failure:(Capability_append_operation_failed failure)
        ~target_binding:(Capability_append_target_check_failed failure)
        ()
    | Ok parent_stat ->
      (match
         Capability_mutation_lease.try_acquire
           (Capability_mutation_lease.Existing_target
              { target_dev = opened_stat.dev
              ; target_ino = opened_stat.ino
              ; parent_dev = parent_stat.dev
              ; parent_ino = parent_stat.ino
              })
       with
       | None ->
         capability_append_outcome
           ~requested_bytes
           ~write_failure:Capability_append_mutation_contended
           ()
       | Some mutation_lease ->
         Fun.protect
           ~finally:(fun () ->
             Capability_mutation_lease.release mutation_lease)
         @@ fun () ->
         (match append_target_binding ~parent ~leaf:leaf_name opened_stat with
          | (Append_target_changed | Append_target_check_failed _) as observation ->
            let target_binding =
              capability_append_target_binding_of_observation observation
            in
            capability_append_outcome ~requested_bytes ~target_binding ()
          | Append_target_verified ->
            let outcome =
              match Eio_unix.Resource.fd_opt resource with
              | None ->
                capability_append_outcome
                  ~requested_bytes
                  ~write_failure:Capability_append_posix_descriptor_unavailable
                  ~target_binding:Capability_append_target_verified
                  ()
              | Some fd ->
                (try
                   Eio_unix.run_in_systhread
                     ~label:"fs-compat-open-file-append"
                     (fun () ->
                        Eio_unix.Fd.use_exn
                          "fs-compat-open-file-append"
                          fd
                          (fun unix_fd ->
                             append_fd_observed
                               ~io:capability_append_unix_io
                               ~fd:unix_fd
                               content))
                 with
                 | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
                 | exception_ ->
                   let backtrace = Printexc.get_raw_backtrace () in
                   capability_append_outcome
                     ~requested_bytes
                     ~write_failure:
                       (Capability_append_operation_failed
                          (capability_append_operation_failure
                             exception_
                             backtrace))
                     ~target_binding:Capability_append_target_verified
                     ())
            in
            after_write ();
            let target_binding =
              append_target_binding ~parent ~leaf:leaf_name opened_stat
              |> capability_append_target_binding_of_observation
            in
            { outcome with target_binding }))
;;

let append_capability_observed file content =
  append_capability_observed_with ~after_write:(fun () -> ()) file content
;;

module Capability_append_for_testing = struct
  let append_capability_observed = append_capability_observed_with
  let append_fd_observed = append_fd_observed
end
