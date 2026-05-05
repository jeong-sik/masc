(** Per-endpoint admission throttle table.

    Shared throttle map: URL -> Llm_provider.Provider_throttle.t.
    All callers contending for the same local endpoint share one semaphore.
    Populated lazily from Discovery slot data.

    Implementation: lock-free reads via [Provider_throttle.t String_map.t
    Atomic.t]. [populate] pre-builds candidate throttle objects outside
    the CAS retry loop so a retry never re-runs Provider_throttle.create
    side effects (i.e. never allocates a duplicate Slot_scheduler).

    @since 0.91.0
    @since 0.92.0 extracted from Cascade_config
    @since 0.93.2 lock-free reads (Eio.Mutex → Atomic+immutable Map) *)

module String_map = Map.Make (String)

let throttle_table :
  Llm_provider.Provider_throttle.t String_map.t Atomic.t =
  Atomic.make String_map.empty

let has_slot_data (s : Llm_provider.Discovery.endpoint_status) =
  (match s.slots with Some ss -> ss.total > 0 | None -> false)
  || (match s.props with Some p -> p.total_slots > 0 | None -> false)

(* Pre-built operation. The CAS loop applies it without re-running the
   throttle constructor, so [Provider_throttle.of_discovery_status] /
   [default_for_kind] (which allocate a Slot_scheduler) run exactly once
   per [populate] call regardless of CAS contention. *)
type populate_op =
  | Remove of string
  | Maybe_install of {
      url : string;
      candidate : Llm_provider.Provider_throttle.t;
      new_has_slot_data : bool;
    }

let prepare_op (s : Llm_provider.Discovery.endpoint_status) : populate_op =
  if not s.healthy then Remove s.url
  else
    let candidate =
      match Llm_provider.Provider_throttle.of_discovery_status s with
      | Some t -> t
      | None ->
        Llm_provider.Provider_throttle.default_for_kind
          Llm_provider.Provider_config.OpenAI_compat
    in
    Maybe_install
      { url = s.url; candidate; new_has_slot_data = has_slot_data s }

let apply_op
    (m : Llm_provider.Provider_throttle.t String_map.t)
    (op : populate_op) =
  match op with
  | Remove url -> String_map.remove url m
  | Maybe_install { url; candidate; new_has_slot_data } ->
    (match String_map.find_opt url m with
     | None -> String_map.add url candidate m
     | Some existing ->
       if Llm_provider.Provider_throttle.source existing = Fallback
          && new_has_slot_data
       then String_map.add url candidate m
       else m)

let populate (statuses : Llm_provider.Discovery.endpoint_status list) =
  let ops = List.map prepare_op statuses in
  let rec loop () =
    let cur = Atomic.get throttle_table in
    let next = List.fold_left apply_op cur ops in
    if not (Atomic.compare_and_set throttle_table cur next) then loop ()
  in
  loop ()

let lookup url = String_map.find_opt url (Atomic.get throttle_table)

let clear () = Atomic.set throttle_table String_map.empty

let length () = String_map.cardinal (Atomic.get throttle_table)

(* ── Capacity Query ────────────────────────────────────── *)

type capacity_info = {
  total : int;
  process_active : int;
  process_available : int;
  process_queue_length : int;
  source : Llm_provider.Provider_throttle.capacity_source;
}

let capacity url =
  match String_map.find_opt url (Atomic.get throttle_table) with
  | None -> None
  | Some t ->
    let snap = Llm_provider.Provider_throttle.snapshot t in
    Some
      {
        total = snap.max_slots;
        process_active = snap.active;
        process_available = snap.available;
        process_queue_length = snap.queue_length;
        source = Llm_provider.Provider_throttle.source t;
      }
