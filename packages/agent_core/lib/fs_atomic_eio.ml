(** Atomic file save for Eio paths.

    Writes to a writer-unique tmp, fsyncs the tmp file, renames it into
    place, then fsyncs the directory. Unique tmp naming closes the
    concurrent-save race that produced [Eio.Io Fs Not_found
    Unix_error (No such file or directory, "renameat", ...json.tmp)]
    when two fibers wrote to the same logical id (downstream #9780).

    The fsync pair is best-effort: some filesystems reject fsync on
    directories or on the file itself. Where supported, it closes the
    gap where [rename] succeeds but the kernel has not yet written the
    directory block — a crash in that window can resurrect the old
    file or leave a partial one (downstream #9749). *)

let unique_counter = Atomic.make 0

(* Unique suffix: pid + wall-clock nanoseconds + monotonic counter.
   Filesystem names tolerate '.' and '_'. *)
let make_unique_suffix () =
  let pid = Unix.getpid () in
  let now_ns = Int64.of_float (Unix.gettimeofday () *. 1e9) in
  let n = Atomic.fetch_and_add unique_counter 1 in
  Printf.sprintf "%d_%Ld_%d" pid now_ns n
;;

let fsync_fd_best_effort fd =
  try Unix.fsync fd with
  | Unix.Unix_error ((EINVAL | EOPNOTSUPP), _, _) -> ()
;;

let fsync_native_path_best_effort native =
  try
    let fd = Unix.openfile native [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close fd with
        | Unix.Unix_error _ -> ())
      (fun () -> fsync_fd_best_effort fd)
  with
  | Unix.Unix_error _ -> ()
;;

(* Eio.Path.native returns [None] for non-filesystem dirs (rare in
   our callers). Best-effort: skip fsync when we cannot get a native
   path — this degrades crash safety but preserves correctness. *)
let fsync_eio_path_best_effort path =
  match Eio.Path.native path with
  | Some native -> fsync_native_path_best_effort native
  | None -> ()
;;

(** Save [content] atomically to [dir / name].

    Uses a unique tmp name so concurrent calls on the same [name]
    never collide. Best-effort fsync on tmp and parent directory.

    On any error, the tmp is unlinked (best-effort) and the error is
    returned via [Fs_result.io_error_of_exn]. *)
let save_atomic ~(dir : Eio.Fs.dir_ty Eio.Path.t) ~(name : string) (content : string) =
  let tmp_name = name ^ "." ^ make_unique_suffix () ^ ".tmp" in
  let tmp = Eio.Path.(dir / tmp_name) in
  let target = Eio.Path.(dir / name) in
  let cleanup_tmp () =
    try Eio.Path.unlink tmp with
    | Eio.Io _ | Unix.Unix_error _ -> ()
  in
  try
    Eio.Path.save ~create:(`Or_truncate 0o644) tmp content;
    fsync_eio_path_best_effort tmp;
    Eio.Path.rename tmp target;
    fsync_eio_path_best_effort dir;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e ->
    cleanup_tmp ();
    raise e
  | exn ->
    cleanup_tmp ();
    Fs_result.io_error_of_exn ~op:"save_atomic" ~path:name exn
;;
