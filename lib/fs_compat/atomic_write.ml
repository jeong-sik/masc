(* See [atomic_write.mli] for the contract. *)

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
      (fun name -> if Durable_mutation.is_temporary_name name then handle_file dir name)
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
