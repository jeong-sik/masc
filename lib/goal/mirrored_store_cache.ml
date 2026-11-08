(* Shared machinery for the goal-side stores that keep a primary JSON ledger
   with an evidence-only [.last-good] recovery mirror (the RFC-0234/0444
   family: Goal_store, Goal_verification). One owner for the content-addressed
   prepared cache; each store keeps its own load classification and recovery
   policy, which encode domain damage decisions this module must not absorb. *)

module Content_cache = struct
  (* A hit requires exact byte equality against the freshly read document, so
     an out-of-band edit can never serve stale state while unchanged reads
     skip JSON parsing and preparation. [Stdlib.Mutex] is deliberate: the
     critical section performs only in-memory [Hashtbl] and [String] work
     with zero Eio fiber yields, and these stores are called from both Eio
     fibers and plain threads. *)
  type 'prepared t = {
    table : (string, string * 'prepared) Hashtbl.t;
    mutex : Stdlib.Mutex.t;
  }

  let create () = { table = Hashtbl.create 8; mutex = Stdlib.Mutex.create () }

  let with_lock t f =
    Stdlib.Mutex.lock t.mutex;
    Fun.protect
      ~finally:(fun () -> Stdlib.Mutex.unlock t.mutex)
      f

  let clear t path = with_lock t (fun () -> Hashtbl.remove t.table path)

  let find t ~path ~bytes =
    with_lock t (fun () ->
        match Hashtbl.find_opt t.table path with
        | Some (cached_bytes, prepared) when String.equal cached_bytes bytes ->
          Some prepared
        | Some _ | None -> None)

  let replace t path bytes prepared =
    with_lock t (fun () -> Hashtbl.replace t.table path (bytes, prepared))

  (* Probe, then decode and prepare outside the lock, then publish. A failed
     decode leaves the cache untouched — callers that want a stale entry
     dropped on a bad read call [clear] themselves. *)
  let memo t ~path ~bytes
        ~(decode : string -> ('state, 'reason) result)
        ~(prepare : 'state -> 'prepared)
    : ('prepared, 'reason) result =
    match find t ~path ~bytes with
    | Some prepared -> Ok prepared
    | None ->
      (match decode bytes with
       | Error _ as error -> error
       | Ok state ->
         let prepared = prepare state in
         replace t path bytes prepared;
         Ok prepared)
end
