(* RFC-0162 §3.4. See [fd_cache.mli] for the contract. *)

type cached_writer =
  { oc : out_channel
  ; mutable last_used : float
  }

let cached : (string, cached_writer) Hashtbl.t = Hashtbl.create 32
let mu = Stdlib.Mutex.create ()
let max_entries = 32

let close_silently w =
  try Stdlib.close_out w.oc with
  | _ -> ()
;;

(* Evict the writer with the smallest [last_used], close its fd.
   Caller must already hold [mu]. *)
let evict_lru_locked () =
  let oldest = ref None in
  Hashtbl.iter
    (fun path w ->
      match !oldest with
      | None -> oldest := Some (path, w.last_used)
      | Some (_, ts) when w.last_used < ts -> oldest := Some (path, w.last_used)
      | _ -> ())
    cached;
  match !oldest with
  | None -> ()
  | Some (victim_path, _) ->
    (match Hashtbl.find_opt cached victim_path with
     | Some w ->
       close_silently w;
       Hashtbl.remove cached victim_path
     | None -> ())
;;

(* Caller must already hold [mu]. *)
let get_or_open_locked path =
  let now = Unix.gettimeofday () in
  match Hashtbl.find_opt cached path with
  | Some w ->
    w.last_used <- now;
    w.oc
  | None ->
    if Hashtbl.length cached >= max_entries then evict_lru_locked ();
    let oc =
      Stdlib.open_out_gen
        [ Stdlib.Open_append; Stdlib.Open_creat; Stdlib.Open_wronly ]
        0o644
        path
    in
    Hashtbl.add cached path { oc; last_used = now };
    oc
;;

let get_writer path =
  Stdlib.Mutex.protect mu (fun () -> get_or_open_locked path)
;;

let invalidate path =
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt cached path with
    | Some w ->
      close_silently w;
      Hashtbl.remove cached path
    | None -> ())
;;

let close_all () =
  Stdlib.Mutex.protect mu (fun () ->
    Hashtbl.iter (fun _ w -> close_silently w) cached;
    Hashtbl.reset cached)
;;

let reset_for_testing () = close_all ()

(* Best-effort cache drain at process exit. RFC-0108 §6 already
   states per-record fsync is out of scope, so the [flush] inside
   the hot path is the durability boundary; this close is just to
   release the fd handles cleanly. *)
let () = Stdlib.at_exit close_all
