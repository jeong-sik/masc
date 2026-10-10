(* See [atomic_replace.mli] for the contract. *)

(* Atomic replacement with process-restart sync:
   tmp → Unix.fsync(tmp) → rename → Unix.fsync(parent dir).
   The strict path requires both syncs to succeed; the general path retains
   its best-effort handling. This is not a hardware/power-loss
   persistence claim and does not use Darwin F_FULLFSYNC. *)
let fsync_path_with ~allow_unsupported path =
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
      | Unix.Unix_error ((Unix.EINVAL | Unix.EOPNOTSUPP), _, _)
        when allow_unsupported ->
        (* Some filesystems (tmpfs on some kernels) reject fsync. The data
           is still durable to the extent the underlying FS offers. *)
        ())
;;

let fsync_path = fsync_path_with ~allow_unsupported:true
let fsync_path_strict = fsync_path_with ~allow_unsupported:false

(* An atomic replacement is blocking syscalls from start to end: creating
   the temp file (an O_EXCL open per name tried), writing the payload,
   fsync of the payload, rename over the target, fsync of the parent
   directory. Inside an Eio fiber the whole replacement runs as one
   systhread job so the domain keeps scheduling other fibers while the
   kernel works; a single rename held the main domain for 486 ms, temp-file
   creation was 3.7% of its busy time, and the payload write of a 2 MB
   file 120-130 ms per call in the 2026-09-05/06 profiles (RFC
   main-domain-scheduler-latency §8.8). Outside Eio it runs inline. The
   injected [save_file] must be a blocking writer: it is called inside the
   job, where no Eio effect can be performed.
   [Eio_unix.run_in_systhread] re-raises the job's exception in the fiber
   with the backtrace captured in the thread (eio/unix/thread_pool.ml), so
   the failure stage and cancellation reporting below are unchanged. *)
let blocking_syscalls ~label f =
  match Execution_context.current () with
  | Execution_context.Non_eio -> f ()
  | Execution_context.Eio_fiber -> Eio_unix.run_in_systhread ~label f
;;

let open_atomic_temp_file ~temp_dir () =
  (* Open_binary: the durable raw-bytes path promises the caller's exact
     bytes. stdlib defaults this to [Open_text], which rewrites newlines on
     platforms that separate the two modes. *)
  Stdlib.Filename.open_temp_file
    ~mode:[ Open_binary ]
    ~temp_dir
    Atomic_temp_name.prefix
    Atomic_temp_name.suffix
;;

type atomic_replace_failure_stage =
  | Before_rename
  | After_rename

type atomic_replace_failure =
  { path : string
  ; stage : atomic_replace_failure_stage
  ; exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

let atomic_replace_failure_to_string failure =
  Printf.sprintf
    "save_file_atomic %s: %s"
    failure.path
    (Printexc.to_string failure.exception_)
;;

let write_file_atomic_with_parent_sync
  ?(run = blocking_syscalls)
  ~sync_file
  ~sync_parent
  ~(write_temp : string -> unit)
  (path : string)
  : (unit, atomic_replace_failure) Result.t
  =
  let dir = Stdlib.Filename.dirname path in
  let stage = ref Before_rename in
  let failure ~backtrace exception_ =
    Error { path; stage = !stage; exception_; backtrace }
  in
  run
    ~label:("fs-compat-atomic-replace " ^ Stdlib.Filename.basename path)
    (fun () ->
    match
      try
        Ok
          (Stdlib.Filename.temp_file
             ~temp_dir:dir
             Atomic_temp_name.prefix
             Atomic_temp_name.suffix)
      with
      (* Filename.temp_file's only documented failure is Sys_error; anything
         else (Out_of_memory, Assert_failure, ...) is fatal and must stay loud
         rather than collapse into the staged error channel. *)
      | Sys_error _ as exception_ ->
        let backtrace = Printexc.get_raw_backtrace () in
        failure ~backtrace exception_
    with
    | Error _ as error -> error
    | Ok tmp ->
      (try
         write_temp tmp;
         sync_file tmp;
         Stdlib.Sys.rename tmp path;
         stage := After_rename;
         sync_parent dir;
         Ok ()
       with
       | Eio.Cancel.Cancelled _ as exn ->
         (* The stage file goes before the cancellation leaves, the same way
            the failure arm below removes it -- otherwise a cancelled replace
            is the one exit that leaves an orphan behind. Sys.remove performs
            no Eio operation, so it completes while unwinding; past a
            successful rename tmp is already gone and Sys_error absorbs it.

            The backtrace is taken before the removal, the same way the arm
            below takes it. Sys_error being raised and caught in between
            replaces the trace the runtime holds, so a bare re-raise after
            the cleanup would hand on that one instead of the origin. *)
         let backtrace = Printexc.get_raw_backtrace () in
         (try Stdlib.Sys.remove tmp with
          | Sys_error _ -> ());
         Printexc.raise_with_backtrace exn backtrace
       | exception_ ->
         let backtrace = Printexc.get_raw_backtrace () in
         (try Stdlib.Sys.remove tmp with
          | Sys_error _ -> ());
         failure ~backtrace exception_))
;;

let string_error_result = function
  | Ok () -> Ok ()
  | Error failure ->
    (match failure.exception_ with
     | Eio.Cancel.Cancelled _ ->
       Printexc.raise_with_backtrace failure.exception_ failure.backtrace
     | _ -> Error (atomic_replace_failure_to_string failure))
;;

let save_file_atomic ~save_file path content =
  write_file_atomic_with_parent_sync
    ~sync_file:fsync_path
    ~sync_parent:(fun dir ->
      try fsync_path dir with
      | Unix.Unix_error _ -> ())
    ~write_temp:(fun tmp -> save_file tmp content)
    path
  |> string_error_result
;;

(* No fsync at all: tmp -> rename. The rename still replaces the target in
   one step, so a reader never sees half of the old file and half of the
   new one, but after a power loss the renamed file can be empty or hold
   only part of [content]. Only a caller that rebuilds the file on its next
   pass may use it (#37503: the binary's own tool and MCP assets). *)
let save_file_atomic_rename_only ~save_file path content =
  write_file_atomic_with_parent_sync
    ~sync_file:(fun (_ : string) -> ())
    ~sync_parent:(fun (_ : string) -> ())
    ~write_temp:(fun tmp -> save_file tmp content)
    path
  |> string_error_result
;;

let save_file_atomic_strict_staged ~save_file path content =
  write_file_atomic_with_parent_sync
    ~sync_file:fsync_path_strict
    ~sync_parent:fsync_path_strict
    ~write_temp:(fun tmp -> save_file tmp content)
    path
;;

let write_temp_channel ~write path =
  let channel = Stdlib.open_out_bin path in
  (* fun-protect-finally-ok: runs inside [blocking_syscalls], outside Eio;
     closing the stdlib channel performs no fiber operation. *)
  Fun.protect
    ~finally:(fun () -> Stdlib.close_out_noerr channel)
    (fun () ->
       write channel;
       (* A failed flush/close is a failed staged write, before the rename. *)
       Stdlib.close_out channel)
;;

let write_file_atomic_strict_staged path ~write =
  write_file_atomic_with_parent_sync
    ~sync_file:fsync_path_strict
    ~sync_parent:fsync_path_strict
    ~write_temp:(write_temp_channel ~write)
    path
;;

let write_file_atomic_strict_staged_blocking path ~write =
  write_file_atomic_with_parent_sync
    ~run:(fun ~label:_ f -> f ())
    ~sync_file:fsync_path_strict
    ~sync_parent:fsync_path_strict
    ~write_temp:(write_temp_channel ~write)
    path
;;

let save_file_atomic_strict ~save_file path content =
  save_file_atomic_strict_staged ~save_file path content
  |> string_error_result
;;

module For_testing = struct
  let save_file_atomic_strict_staged
      ?(sync_file = fsync_path_strict)
      ~sync_parent
      ~save_file
      path
      content
    =
    write_file_atomic_with_parent_sync
      ~sync_file
      ~sync_parent
      ~write_temp:(fun tmp -> save_file tmp content)
      path
  ;;

  let write_file_atomic_strict_staged
      ?(sync_file = fsync_path_strict)
      ~sync_parent
      path
      ~write
    =
    write_file_atomic_with_parent_sync
      ~sync_file
      ~sync_parent
      ~write_temp:(write_temp_channel ~write)
      path
  ;;
end
