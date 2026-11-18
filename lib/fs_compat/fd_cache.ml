(* RFC-0162 §3.4. See [fd_cache.mli] for the contract. *)

type cached_writer =
  { fd : Unix.file_descr
  ; mutable last_used : float
  ; mutable active : int
  ; mutable close_on_release : bool
  }

let cached : (string, cached_writer) Hashtbl.t = Hashtbl.create 32
let mu = Stdlib.Mutex.create ()
let max_entries = 32

(* The descriptor has no user-space buffer, so closing it writes nothing. *)
let close_silently w =
  try Unix.close w.fd with
  | Unix.Unix_error _ -> ()
;;

let drop_cached_writer_locked path w =
  Hashtbl.remove cached path;
  if w.active = 0 then close_silently w else w.close_on_release <- true
;;

(* Evict the inactive writer with the smallest [last_used], closing its fd.
   Caller must already hold [mu]. Active writers are never closed under a
   caller still using the returned channel. *)
let evict_lru_locked () =
  let oldest = ref None in
  Hashtbl.iter
    (fun path w ->
      if w.active = 0
      then
        match !oldest with
        | None -> oldest := Some (path, w.last_used)
        | Some (_, ts) when w.last_used < ts -> oldest := Some (path, w.last_used)
        | _ -> ())
    cached;
  match !oldest with
  | None -> ()
  | Some (victim_path, _) ->
    (match Hashtbl.find_opt cached victim_path with
     | Some w -> drop_cached_writer_locked victim_path w
     | None -> ())
;;

let writer_matches_path path w =
  try
    let opened = Unix.fstat w.fd in
    let current = Unix.stat path in
    opened.Unix.st_dev = current.Unix.st_dev
    && opened.Unix.st_ino = current.Unix.st_ino
  with
  | Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> false
;;

(* Caller must already hold [mu]. *)
let get_or_open_locked path now =
  (match Hashtbl.find_opt cached path with
   | Some w when not (writer_matches_path path w) -> drop_cached_writer_locked path w
   | Some _ | None -> ());
  match Hashtbl.find_opt cached path with
  | Some w ->
    w.last_used <- now;
    w
  | None ->
    if Hashtbl.length cached >= max_entries then evict_lru_locked ();
    (* [Sys_error] with the path first is what [Stdlib.open_out_gen] raised
       here before; the append callers document and catch [Sys_error].
       [O_RDWR]: a line append reads the file's last byte through this
       descriptor. *)
    let fd =
      try
        Unix.openfile
          path
          [ Unix.O_RDWR; Unix.O_APPEND; Unix.O_CREAT; Unix.O_CLOEXEC ]
          0o644
      with
      | Unix.Unix_error (error, _, _) ->
        raise (Sys_error (path ^ ": " ^ Unix.error_message error))
    in
    let w = { fd; last_used = now; active = 0; close_on_release = false } in
    Hashtbl.add cached path w;
    w
;;

let with_writer path f =
  let w =
    Stdlib.Mutex.protect mu (fun () ->
      (* NDT-OK: fd-cache recency is runtime resource metadata only; append
         ordering and file contents are determined by caller writes. *)
      let now = Unix.gettimeofday () in
      let w = get_or_open_locked path now in
      w.last_used <- now;
      w.active <- w.active + 1;
      w)
  in
  Fun.protect
    ~finally:(fun () ->
      Stdlib.Mutex.protect mu (fun () ->
        w.active <- max 0 (w.active - 1);
        (* NDT-OK: update LRU recency after use; it only influences future
           inactive fd eviction, never persisted annotation semantics. *)
        w.last_used <- Unix.gettimeofday ();
        if w.active = 0 && w.close_on_release then close_silently w))
    (fun () -> f w.fd)
;;

let invalidate path =
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt cached path with
    | Some w -> drop_cached_writer_locked path w
    | None -> ())
;;

let close_all () =
  Stdlib.Mutex.protect mu (fun () ->
    let entries = Hashtbl.fold (fun path w acc -> (path, w) :: acc) cached [] in
    List.iter (fun (path, w) -> drop_cached_writer_locked path w) entries)
;;

let reset_for_testing () = close_all ()

(* Release the descriptors at process exit. Every append has reached the
   kernel before it returned and nothing is buffered here, so this close
   writes nothing. RFC-0108 §6 keeps per-record fsync out of scope. *)
let () = Stdlib.at_exit close_all
