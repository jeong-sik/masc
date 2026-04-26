(** Per-endpoint admission throttle table.

    Shared throttle table: URL -> Llm_provider.Provider_throttle.t.
    All callers contending for the same local endpoint share one semaphore.
    Populated lazily from Discovery slot data.

    @since 0.91.0
    @since 0.92.0 extracted from Cascade_config *)

let throttle_table : (string, Llm_provider.Provider_throttle.t) Hashtbl.t =
  Hashtbl.create 4
;;

let throttle_mu = Eio.Mutex.create ()

let has_slot_data (s : Llm_provider.Discovery.endpoint_status) =
  (match s.slots with
   | Some ss -> ss.total > 0
   | None -> false)
  ||
  match s.props with
  | Some p -> p.total_slots > 0
  | None -> false
;;

let populate (statuses : Llm_provider.Discovery.endpoint_status list) =
  Eio.Mutex.use_rw ~protect:true throttle_mu (fun () ->
    List.iter
      (fun (s : Llm_provider.Discovery.endpoint_status) ->
         if not s.healthy
         then
           (* Evict stale entry so next healthy probe reinstalls a fresh semaphore. *)
           Hashtbl.remove throttle_table s.url
         else (
           let existing = Hashtbl.find_opt throttle_table s.url in
           let should_install =
             match existing with
             | None -> true
             | Some t ->
               (* Promote Fallback → Discovered when better data arrives *)
               Llm_provider.Provider_throttle.source t = Fallback && has_slot_data s
           in
           if should_install
           then (
             let t =
               match Llm_provider.Provider_throttle.of_discovery_status s with
               | Some t -> t
               | None ->
                 Llm_provider.Provider_throttle.default_for_kind
                   Llm_provider.Provider_config.OpenAI_compat
             in
             Hashtbl.replace throttle_table s.url t)))
      statuses)
;;

let lookup url =
  Eio.Mutex.use_ro throttle_mu (fun () -> Hashtbl.find_opt throttle_table url)
;;

let clear () =
  Eio.Mutex.use_rw ~protect:true throttle_mu (fun () -> Hashtbl.clear throttle_table)
;;

let length () = Eio.Mutex.use_ro throttle_mu (fun () -> Hashtbl.length throttle_table)

(* ── Capacity Query ────────────────────────────────────── *)

type capacity_info =
  { total : int
  ; process_active : int
  ; process_available : int
  ; process_queue_length : int
  ; source : Llm_provider.Provider_throttle.capacity_source
  }

let capacity url =
  Eio.Mutex.use_ro throttle_mu (fun () ->
    match Hashtbl.find_opt throttle_table url with
    | None -> None
    | Some t ->
      let snap = Llm_provider.Provider_throttle.snapshot t in
      Some
        { total = snap.max_slots
        ; process_active = snap.active
        ; process_available = snap.available
        ; process_queue_length = snap.queue_length
        ; source = Llm_provider.Provider_throttle.source t
        })
;;
