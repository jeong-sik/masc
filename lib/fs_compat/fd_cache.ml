(* RFC-0162 §3.4. See [fd_cache.mli] for the contract. *)

type cached_writer =
  { oc : out_channel
  ; mutable last_used : float
  ; mutable active : int
  ; mutable close_on_release : bool
  }

let cached : (string, cached_writer) Hashtbl.t = Hashtbl.create 32
let mu = Stdlib.Mutex.create ()
let max_entries = 32

let close_silently w =
  try Stdlib.close_out w.oc with
  | _ -> ()
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

(* Caller must already hold [mu]. *)
let get_or_open_locked path now =
  match Hashtbl.find_opt cached path with
  | Some w ->
    w.last_used <- now;
    w
  | None ->
    if Hashtbl.length cached >= max_entries then evict_lru_locked ();
    let oc =
      Stdlib.open_out_gen
        [ Stdlib.Open_append; Stdlib.Open_creat; Stdlib.Open_wronly ]
        0o644
        path
    in
    let w = { oc; last_used = now; active = 0; close_on_release = false } in
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
    (fun () -> f w.oc)
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

(* Best-effort cache drain at process exit. RFC-0108 §6 already
   states per-record fsync is out of scope, so the [flush] inside
   the hot path is the durability boundary; this close is just to
   release the fd handles cleanly. *)
let () = Stdlib.at_exit close_all
