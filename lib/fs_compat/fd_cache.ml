(* RFC-0162 §3.4. See [fd_cache.mli] for the contract. *)

type cached_writer =
  { target : Fd_append_whole.target
  ; mutable last_used : float
  ; mutable active : int
  ; mutable close_on_release : bool
  }

let cached : (string, cached_writer) Hashtbl.t = Hashtbl.create 32
let mu = Stdlib.Mutex.create ()
let max_entries = 32

(* Opens in flight, guarded by [mu]. Each made room for its descriptor
   before it started, so it holds a place in the cache until it ends. *)
let opening = ref 0
let held_locked () = Hashtbl.length cached + !opening

(* The descriptor has no user-space buffer, so closing it writes nothing. *)
let close_silently w =
  try Unix.close (Fd_append_whole.descriptor w.target) with
  | Unix.Unix_error _ -> ()
;;

let drop_cached_writer_locked path w =
  Hashtbl.remove cached path;
  if w.active = 0 then close_silently w else w.close_on_release <- true
;;

(* Evict the inactive writer with the smallest [last_used], closing its fd,
   and say whether there was one. Caller must already hold [mu]. Active
   writers are never closed under a caller still using the lent descriptor. *)
let evict_lru_locked () =
  let oldest =
    Hashtbl.fold
      (fun path w oldest ->
        if w.active > 0
        then oldest
        else (
          match oldest with
          | Some (_, older) when older.last_used <= w.last_used -> oldest
          | Some _ | None -> Some (path, w)))
      cached
      None
  in
  match oldest with
  | None -> false
  | Some (path, w) ->
    drop_cached_writer_locked path w;
    true
;;

(* Caller must already hold [mu]. Closes inactive writers, least recently
   used first, until at most [places] are held or every cached writer is
   lent. *)
let rec evict_down_to_locked places =
  if held_locked () > places && evict_lru_locked () then evict_down_to_locked places
;;

(* [Sys_error] with the path first is what [Stdlib.open_out_gen] raised for
   an open failure before the cache held descriptors; the append callers
   document and catch [Sys_error]. Every path error leaves the cache in
   that shape. *)
let sys_error path error = Sys_error (path ^ ": " ^ Unix.error_message error)

let writer_matches_path path w =
  match
    let opened = Unix.fstat (Fd_append_whole.descriptor w.target) in
    let current = Unix.stat path in
    opened.Unix.st_dev = current.Unix.st_dev
    && opened.Unix.st_ino = current.Unix.st_ino
  with
  | same -> same
  | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> false
  | exception Unix.Unix_error (error, _, _) -> raise (sys_error path error)
;;

(* Caller must already hold [mu]. The cached writer whose descriptor still
   names the file at [path]; one that no longer does is dropped. *)
let find_current_locked path =
  match Hashtbl.find_opt cached path with
  | Some w when writer_matches_path path w -> Some w
  | Some w ->
    drop_cached_writer_locked path w;
    None
  | None -> None
;;

(* Caller must already hold [mu]. *)
let lease_locked w =
  (* NDT-OK: fd-cache recency is runtime resource metadata only; append
     ordering and file contents are determined by caller writes. *)
  w.last_used <- Unix.gettimeofday ();
  w.active <- w.active + 1;
  w
;;

(* The open runs outside [mu]. Opening a FIFO waits for its reader, and
   that wait holds up the appends of this path only. *)
let open_writer path =
  let target =
    try Fd_append_whole.open_target path with
    | Unix.Unix_error (error, _, _) -> raise (sys_error path error)
  in
  { target; last_used = 0.0; active = 0; close_on_release = false }
;;

let lease path =
  match
    Stdlib.Mutex.protect mu (fun () ->
      match find_current_locked path with
      | Some w -> Some (lease_locked w)
      | None ->
        (* Room is made before the open, not after it: a process at its
           descriptor limit with a full cache has no descriptor left for
           the open until one cached writer is closed. When the open then
           fails, that writer was closed for nothing and is opened again
           by its next append. *)
        evict_down_to_locked (max_entries - 1);
        incr opening;
        None)
  with
  | Some w -> w
  | None ->
    let opened =
      match open_writer path with
      | opened -> opened
      | exception exception_ ->
        let backtrace = Printexc.get_raw_backtrace () in
        Stdlib.Mutex.protect mu (fun () -> decr opening);
        Printexc.raise_with_backtrace exception_ backtrace
    in
    Stdlib.Mutex.protect mu (fun () ->
      decr opening;
      match find_current_locked path with
      | exception exception_ ->
        let backtrace = Printexc.get_raw_backtrace () in
        close_silently opened;
        Printexc.raise_with_backtrace exception_ backtrace
      | Some w ->
        (* Another caller cached a writer for this path during the open. *)
        close_silently opened;
        lease_locked w
      | None ->
        (* The place this open held becomes the writer's. *)
        Hashtbl.add cached path opened;
        lease_locked opened)
;;

let with_writer path f =
  let w = lease path in
  Fun.protect
    ~finally:(fun () ->
      Stdlib.Mutex.protect mu (fun () ->
        w.active <- max 0 (w.active - 1);
        (* NDT-OK: update LRU recency after use; it only influences future
           inactive fd eviction, never persisted annotation semantics. *)
        w.last_used <- Unix.gettimeofday ();
        if w.active = 0 && w.close_on_release then close_silently w;
        (* More than [max_entries] places are held only while that many
           are lent or held by opens in flight at once. The cache comes
           back to its bound as writers are returned and opens end. *)
        evict_down_to_locked max_entries))
    (fun () -> f w.target)
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
   writes nothing. Neither an append nor this close calls fsync. *)
let () = Stdlib.at_exit close_all
