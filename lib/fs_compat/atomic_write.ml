(* See [atomic_write.mli] for the contract. *)

(* Durable atomic write: tmp → fsync(tmp) → rename → fsync(parent dir).
   Without the fsync pair, a crash between the rename and the kernel's
   dirty-page flush can leave the target truncated or zero-length —
   observed on backlog.json after an abrupt shutdown (2026-04-18). *)
let fsync_path path =
  let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
  Stdlib.Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () -> Unix.fsync fd)
;;

(* #10205 finding 2: keep the atomic-tmp filename shape in one place
   so the writer ([save_file_atomic]) and the orphan-sweep matcher
   ([is_atomic_orphan_name]) cannot drift independently. A
   prefix/suffix change on one side without the other would cause
   the sweep to either miss live orphans or scoop unrelated tmp
   files. *)
let atomic_tmp_prefix = ".atomic_"
let atomic_tmp_suffix = ".tmp"

type failure_stage =
  | Not_renamed
  | Renamed_durability_uncertain

type failure =
  { stage : failure_stage
  ; message : string
  }

let failure_to_string failure = failure.message

let save_file_atomic_detailed
  ~(save_file : string -> string -> unit)
  (path : string)
  (content : string)
  : (unit, failure) Result.t
  =
  let dir = Stdlib.Filename.dirname path in
  let tmp = ref None in
  let renamed = ref false in
  let cleanup_tmp () =
    match !tmp with
    | None -> ()
    | Some tmp_path ->
      (try Stdlib.Sys.remove tmp_path with
       | Sys_error _ -> ())
  in
  try
    let tmp_path =
      Stdlib.Filename.temp_file
        ~temp_dir:dir
        atomic_tmp_prefix
        atomic_tmp_suffix
    in
    tmp := Some tmp_path;
    save_file tmp_path content;
    fsync_path tmp_path;
    Stdlib.Sys.rename tmp_path path;
    renamed := true;
    fsync_path dir;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e ->
    cleanup_tmp ();
    raise e
  | exn ->
    cleanup_tmp ();
    Error
      { stage =
          (if !renamed then Renamed_durability_uncertain else Not_renamed)
      ; message =
          Printf.sprintf
            "save_file_atomic %s: %s"
            path
            (Printexc.to_string exn)
      }
;;

let save_file_atomic ~save_file path content =
  save_file_atomic_detailed ~save_file path content
  |> Result.map_error failure_to_string
;;

let is_atomic_orphan_name name =
  let n = String.length name in
  let p = String.length atomic_tmp_prefix in
  let s = String.length atomic_tmp_suffix in
  n >= p + s
  && String.starts_with name ~prefix:atomic_tmp_prefix
  && String.ends_with ~suffix:atomic_tmp_suffix name
;;

let cleanup_atomic_orphans
  ~(mkdir_p_unix : string -> unit)
  ~(base_path : string)
  ?(recovered_subdir = ".recovered")
  ()
  : int * int
  =
  let recovered_dir = Stdlib.Filename.concat base_path recovered_subdir in
  let deleted = ref 0 in
  let preserved = ref 0 in
  (* #10205 finding 3: previous body reinvented [mkdir_p] inline with
     [Stdlib.Sys.file_exists]+[Unix.mkdir]+[Unix.Unix_error _] swallowing.
     [mkdir_p_unix] is recursive, idempotent (handles [EEXIST] precisely
     instead of swallowing every [Unix_error]), and correct when
     [base_path] itself does not exist yet (boot-time race). *)
  let ensure_recovered_dir () =
    try mkdir_p_unix recovered_dir with
    | Unix.Unix_error _ -> ()
  in
  let handle_file dir name =
    let path = Stdlib.Filename.concat dir name in
    match Unix.stat path with
    | exception Unix.Unix_error _ -> ()
    | stat when stat.Unix.st_size = 0 ->
      (try
         Stdlib.Sys.remove path;
         incr deleted
       with
       | Sys_error _ -> ())
    | _stat ->
      ensure_recovered_dir ();
      let target =
        Stdlib.Filename.concat
          recovered_dir
          (Printf.sprintf "%s.%.0f" name (Unix.gettimeofday () *. 1000.0))
      in
      (try
         Stdlib.Sys.rename path target;
         incr preserved
       with
       | Sys_error _ | Unix.Unix_error _ -> ())
  in
  let scan_dir dir entries =
    Array.iter
      (fun name -> if is_atomic_orphan_name name then handle_file dir name)
      entries
  in
  let read_dir_entries dir =
    match Stdlib.Sys.readdir dir with
    | exception Sys_error _ -> [||]
    | entries -> entries
  in
  (* #10205 finding 4: previous body called [Stdlib.Sys.readdir base_path]
     twice — once via [scan_dir] for orphan-find, once for the
     subdirectory recursion pass. Read once, run both passes against
     the cached entry array. *)
  let entries = read_dir_entries base_path in
  scan_dir base_path entries;
  Array.iter
    (fun name ->
      if String.equal name recovered_subdir
      then ()
      else (
        let sub = Stdlib.Filename.concat base_path name in
        match Unix.stat sub with
        | exception Unix.Unix_error _ -> ()
        | stat when stat.Unix.st_kind = Unix.S_DIR ->
          scan_dir sub (read_dir_entries sub)
        | _ -> ()))
    entries;
  !deleted, !preserved
;;
