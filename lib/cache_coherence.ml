(** Cache Coherence — MESI Protocol for Multi-Agent Cache Hierarchy

    Implements the MESI (Modified-Exclusive-Shared-Invalid) cache coherence
    protocol adapted for MASC-MCP multi-agent systems.

    Architecture:
    - L1: In-memory per-agent cache (Hashtbl, ephemeral)
    - L2: Room-scoped file cache (.masc/cache/, existing cache_eio.ml)
    - L3: PostgreSQL (optional, cross-room)

    Coherence bus is mapped to SSE events:
    - cache_invalidate (BusInv): Writer invalidates other agents' L1
    - cache_read_request (BusRd): Reader probes for data
    - cache_write_notify (BusRdX): Writer announces exclusive access

    @since Phase 2 — SWARM-RISC *)

(* ================================================================ *)
(* MESI State Machine                                               *)
(* ================================================================ *)

(** MESI line states *)
type mesi_state =
  | Modified   (** Dirty, sole owner. Snoop-read triggers flush + transition to Shared *)
  | Exclusive  (** Clean, sole owner. Write transitions to Modified, snoop-read to Shared *)
  | Shared     (** Multiple agents hold. Write requires invalidation of others first *)
  | Invalid    (** Stale or absent. Read triggers fetch from L2/L3 *)

let mesi_to_string = function
  | Modified -> "M" | Exclusive -> "E" | Shared -> "S" | Invalid -> "I"

let mesi_of_string = function
  | "M" -> Some Modified | "E" -> Some Exclusive
  | "S" -> Some Shared | "I" -> Some Invalid | _ -> None

(** Coherence bus messages (mapped to SSE events) *)
type bus_message =
  | BusRd of { key: string; requester: string }
      (** Read request: agent needs data *)
  | BusRdX of { key: string; requester: string }
      (** Read-exclusive: agent wants to write *)
  | BusInv of { key: string; invalidator: string }
      (** Invalidate: writer tells others to drop *)
  | BusFlush of { key: string; flusher: string; value: string }
      (** Flush: modified line written back to L2 before sharing *)

let bus_message_to_string = function
  | BusRd { key; requester } ->
      Printf.sprintf "BusRd(key=%s, requester=%s)" key requester
  | BusRdX { key; requester } ->
      Printf.sprintf "BusRdX(key=%s, requester=%s)" key requester
  | BusInv { key; invalidator } ->
      Printf.sprintf "BusInv(key=%s, invalidator=%s)" key invalidator
  | BusFlush { key; flusher; _ } ->
      Printf.sprintf "BusFlush(key=%s, flusher=%s)" key flusher

(** Result of a MESI state transition *)
type transition_result = {
  new_state: mesi_state;
  bus_action: bus_message option;  (** Message to put on coherence bus *)
  writeback: bool;                 (** Whether to flush dirty data to L2 *)
}

(** MESI state transition table.
    Returns (new_state, bus_action, writeback_needed) for each event.

    Transitions follow the standard MESI protocol:
    - Local read miss → BusRd, fetch from L2 → E (sole) or S (shared)
    - Local write miss → BusRdX, invalidate others → M
    - Local write hit on S → BusInv, invalidate others → M
    - Snoop read on M → flush to L2, → S
    - Snoop read on E → → S
    - Snoop invalidate → → I
*)
let transition ~(current : mesi_state) ~(event : [`LocalRead | `LocalWrite | `SnoopRead | `SnoopInvalidate])
    ~agent_id ~key : transition_result =
  match current, event with
  (* Invalid + LocalRead → Exclusive (assume sole reader until snoop says otherwise) *)
  | Invalid, `LocalRead ->
      { new_state = Exclusive;
        bus_action = Some (BusRd { key; requester = agent_id });
        writeback = false }

  (* Invalid + LocalWrite → Modified *)
  | Invalid, `LocalWrite ->
      { new_state = Modified;
        bus_action = Some (BusRdX { key; requester = agent_id });
        writeback = false }

  (* Shared + LocalRead → Shared (no state change) *)
  | Shared, `LocalRead ->
      { new_state = Shared; bus_action = None; writeback = false }

  (* Shared + LocalWrite → Modified (must invalidate others) *)
  | Shared, `LocalWrite ->
      { new_state = Modified;
        bus_action = Some (BusInv { key; invalidator = agent_id });
        writeback = false }

  (* Exclusive + LocalRead → Exclusive (no change) *)
  | Exclusive, `LocalRead ->
      { new_state = Exclusive; bus_action = None; writeback = false }

  (* Exclusive + LocalWrite → Modified (silent upgrade, no bus traffic) *)
  | Exclusive, `LocalWrite ->
      { new_state = Modified; bus_action = None; writeback = false }

  (* Modified + LocalRead → Modified (no change) *)
  | Modified, `LocalRead ->
      { new_state = Modified; bus_action = None; writeback = false }

  (* Modified + LocalWrite → Modified (no change) *)
  | Modified, `LocalWrite ->
      { new_state = Modified; bus_action = None; writeback = false }

  (* Snoop read on Modified → Shared (flush dirty data to L2 first) *)
  | Modified, `SnoopRead ->
      { new_state = Shared;
        bus_action = Some (BusFlush { key; flusher = agent_id; value = "" });
        writeback = true }

  (* Snoop read on Exclusive → Shared *)
  | Exclusive, `SnoopRead ->
      { new_state = Shared; bus_action = None; writeback = false }

  (* Snoop read on Shared → Shared (no change) *)
  | Shared, `SnoopRead ->
      { new_state = Shared; bus_action = None; writeback = false }

  (* Snoop read on Invalid → Invalid (no change) *)
  | Invalid, `SnoopRead ->
      { new_state = Invalid; bus_action = None; writeback = false }

  (* Snoop invalidate on Modified → Invalid (flush first) *)
  | Modified, `SnoopInvalidate ->
      { new_state = Invalid;
        bus_action = Some (BusFlush { key; flusher = agent_id; value = "" });
        writeback = true }

  (* Snoop invalidate on Exclusive → Invalid *)
  | Exclusive, `SnoopInvalidate ->
      { new_state = Invalid; bus_action = None; writeback = false }

  (* Snoop invalidate on Shared → Invalid *)
  | Shared, `SnoopInvalidate ->
      { new_state = Invalid; bus_action = None; writeback = false }

  (* Snoop invalidate on Invalid → Invalid (no-op) *)
  | Invalid, `SnoopInvalidate ->
      { new_state = Invalid; bus_action = None; writeback = false }

(* ================================================================ *)
(* L1 Cache (Per-Agent In-Memory)                                   *)
(* ================================================================ *)

(** A single L1 cache line *)
type cache_line = {
  key: string;
  mutable value: string;
  mutable state: mesi_state;
  mutable last_access: float;
}

(** Per-agent L1 cache *)
type l1_cache = {
  agent_id: string;
  lines: (string, cache_line) Hashtbl.t;
  capacity: int;
  mutable hits: int;
  mutable misses: int;
  mutable invalidations: int;
  mutable writebacks: int;
}

let create_l1 ?(capacity = 64) agent_id =
  { agent_id;
    lines = Hashtbl.create capacity;
    capacity;
    hits = 0;
    misses = 0;
    invalidations = 0;
    writebacks = 0 }

(** Evict LRU line if at capacity *)
let maybe_evict l1 =
  if Hashtbl.length l1.lines >= l1.capacity then begin
    let oldest_key = ref "" in
    let oldest_time = ref infinity in
    Hashtbl.iter (fun k line ->
      if line.last_access < !oldest_time then begin
        oldest_key := k;
        oldest_time := line.last_access
      end
    ) l1.lines;
    if !oldest_key <> "" then begin
      let line = Hashtbl.find l1.lines !oldest_key in
      (* If Modified, must writeback before eviction *)
      if line.state = Modified then
        l1.writebacks <- l1.writebacks + 1;
      Hashtbl.remove l1.lines !oldest_key
    end
  end

(** L1 read: returns (value option, transition_result) *)
let l1_read l1 ~key : string option * transition_result =
  match Hashtbl.find_opt l1.lines key with
  | Some line when line.state <> Invalid ->
      l1.hits <- l1.hits + 1;
      line.last_access <- Time_compat.now ();
      let tr = transition ~current:line.state ~event:`LocalRead
                 ~agent_id:l1.agent_id ~key in
      line.state <- tr.new_state;
      (Some line.value, tr)
  | _ ->
      l1.misses <- l1.misses + 1;
      let tr = transition ~current:Invalid ~event:`LocalRead
                 ~agent_id:l1.agent_id ~key in
      (None, tr)

(** L1 write: update local line, returns transition_result *)
let l1_write l1 ~key ~value : transition_result =
  let current_state =
    match Hashtbl.find_opt l1.lines key with
    | Some line when line.state <> Invalid -> line.state
    | _ -> Invalid
  in
  let tr = transition ~current:current_state ~event:`LocalWrite
             ~agent_id:l1.agent_id ~key in
  maybe_evict l1;
  let now = Time_compat.now () in
  Hashtbl.replace l1.lines key
    { key; value; state = tr.new_state; last_access = now };
  tr

(** L1 snoop: process bus message from another agent *)
let l1_snoop l1 ~msg : transition_result option =
  let key = match msg with
    | BusRd { key; _ } | BusRdX { key; _ }
    | BusInv { key; _ } | BusFlush { key; _ } -> key
  in
  match Hashtbl.find_opt l1.lines key with
  | None -> None
  | Some line when line.state = Invalid -> None
  | Some line ->
      let event = match msg with
        | BusRd _ -> `SnoopRead
        | BusRdX _ | BusInv _ -> `SnoopInvalidate
        | BusFlush _ -> `SnoopRead
      in
      let tr = transition ~current:line.state ~event
                 ~agent_id:l1.agent_id ~key in
      line.state <- tr.new_state;
      if tr.new_state = Invalid then
        l1.invalidations <- l1.invalidations + 1;
      Some tr

(* ================================================================ *)
(* Coherence Controller (Multi-Agent L1 Registry)                   *)
(* ================================================================ *)

(** Coherence metrics *)
type coherence_metrics = {
  total_reads: int;
  total_writes: int;
  l1_hit_rate: float;
  invalidation_count: int;
  writeback_count: int;
  bus_traffic: int;
}

(** Multi-agent coherence controller *)
type coherence_controller = {
  agents: (string, l1_cache) Hashtbl.t;
  mutable bus_traffic: int;
  mutable total_reads: int;
  mutable total_writes: int;
}

let create_controller () =
  { agents = Hashtbl.create 16;
    bus_traffic = 0;
    total_reads = 0;
    total_writes = 0 }

(** Register an agent's L1 cache *)
let register_agent ctrl ?(capacity = 64) agent_id =
  if not (Hashtbl.mem ctrl.agents agent_id) then
    Hashtbl.replace ctrl.agents agent_id (create_l1 ~capacity agent_id)

(** Remove an agent's L1 cache *)
let unregister_agent ctrl agent_id =
  Hashtbl.remove ctrl.agents agent_id

(** Broadcast bus message to all agents except sender *)
let broadcast_snoop ctrl ~sender msg =
  ctrl.bus_traffic <- ctrl.bus_traffic + 1;
  Hashtbl.iter (fun agent_id l1 ->
    if agent_id <> sender then
      ignore (l1_snoop l1 ~msg)
  ) ctrl.agents

(** Coherent read: L1 check → L2 fallback → update L1 *)
let coherent_read ctrl ~agent_id ~key ~(l2_fetch : string -> string option) : string option =
  ctrl.total_reads <- ctrl.total_reads + 1;
  match Hashtbl.find_opt ctrl.agents agent_id with
  | None -> l2_fetch key  (* Unregistered agent, direct L2 *)
  | Some l1 ->
      let (l1_value, tr) = l1_read l1 ~key in
      (* Broadcast bus action if needed *)
      (match tr.bus_action with
       | Some msg -> broadcast_snoop ctrl ~sender:agent_id msg
       | None -> ());
      match l1_value with
      | Some v -> Some v  (* L1 hit *)
      | None ->
          (* L1 miss: fetch from L2 *)
          match l2_fetch key with
          | None -> None
          | Some v ->
              (* Install in L1 as Exclusive (sole cached copy) *)
              maybe_evict l1;
              let now = Time_compat.now () in
              Hashtbl.replace l1.lines key
                { key; value = v; state = Exclusive; last_access = now };
              Some v

(** Coherent write: update L1 + invalidate others + write-through to L2 *)
let coherent_write ctrl ~agent_id ~key ~value
    ~(l2_write : string -> string -> unit) : unit =
  ctrl.total_writes <- ctrl.total_writes + 1;
  match Hashtbl.find_opt ctrl.agents agent_id with
  | None -> l2_write key value  (* Unregistered agent, direct L2 *)
  | Some l1 ->
      let tr = l1_write l1 ~key ~value in
      (* Broadcast bus action if needed *)
      (match tr.bus_action with
       | Some msg -> broadcast_snoop ctrl ~sender:agent_id msg
       | None -> ());
      (* Write-through to L2 for durability *)
      l2_write key value

(** Get metrics for a specific agent *)
let agent_metrics ctrl agent_id : coherence_metrics option =
  match Hashtbl.find_opt ctrl.agents agent_id with
  | None -> None
  | Some l1 ->
      let total = l1.hits + l1.misses in
      let hit_rate = if total > 0 then
        float_of_int l1.hits /. float_of_int total
      else 0.0
      in
      Some { total_reads = ctrl.total_reads;
             total_writes = ctrl.total_writes;
             l1_hit_rate = hit_rate;
             invalidation_count = l1.invalidations;
             writeback_count = l1.writebacks;
             bus_traffic = ctrl.bus_traffic }

(** Get aggregate metrics across all agents *)
let aggregate_metrics ctrl : coherence_metrics =
  let total_hits = ref 0 in
  let total_misses = ref 0 in
  let total_inv = ref 0 in
  let total_wb = ref 0 in
  Hashtbl.iter (fun _id l1 ->
    total_hits := !total_hits + l1.hits;
    total_misses := !total_misses + l1.misses;
    total_inv := !total_inv + l1.invalidations;
    total_wb := !total_wb + l1.writebacks
  ) ctrl.agents;
  let total = !total_hits + !total_misses in
  { total_reads = ctrl.total_reads;
    total_writes = ctrl.total_writes;
    l1_hit_rate = (if total > 0 then float_of_int !total_hits /. float_of_int total else 0.0);
    invalidation_count = !total_inv;
    writeback_count = !total_wb;
    bus_traffic = ctrl.bus_traffic }

(** Get the MESI state of a specific key in an agent's L1 *)
let get_line_state ctrl ~agent_id ~key : mesi_state option =
  match Hashtbl.find_opt ctrl.agents agent_id with
  | None -> None
  | Some l1 ->
      match Hashtbl.find_opt l1.lines key with
      | None -> Some Invalid
      | Some line -> Some line.state

(** List all non-Invalid lines in an agent's L1 *)
let list_lines ctrl ~agent_id : (string * mesi_state) list =
  match Hashtbl.find_opt ctrl.agents agent_id with
  | None -> []
  | Some l1 ->
      Hashtbl.fold (fun k line acc ->
        if line.state <> Invalid then (k, line.state) :: acc
        else acc
      ) l1.lines []

(* ================================================================ *)
(* JSON Serialization                                               *)
(* ================================================================ *)

let mesi_to_yojson state : Yojson.Safe.t =
  `String (mesi_to_string state)

let bus_message_to_yojson msg : Yojson.Safe.t =
  match msg with
  | BusRd { key; requester } ->
      `Assoc [("type", `String "BusRd"); ("key", `String key); ("requester", `String requester)]
  | BusRdX { key; requester } ->
      `Assoc [("type", `String "BusRdX"); ("key", `String key); ("requester", `String requester)]
  | BusInv { key; invalidator } ->
      `Assoc [("type", `String "BusInv"); ("key", `String key); ("invalidator", `String invalidator)]
  | BusFlush { key; flusher; value } ->
      `Assoc [("type", `String "BusFlush"); ("key", `String key);
              ("flusher", `String flusher); ("value_len", `Int (String.length value))]

let metrics_to_yojson (m : coherence_metrics) : Yojson.Safe.t =
  `Assoc [
    ("total_reads", `Int m.total_reads);
    ("total_writes", `Int m.total_writes);
    ("l1_hit_rate", `Float m.l1_hit_rate);
    ("invalidation_count", `Int m.invalidation_count);
    ("writeback_count", `Int m.writeback_count);
    ("bus_traffic", `Int m.bus_traffic);
  ]

let line_to_yojson (key, state) : Yojson.Safe.t =
  `Assoc [("key", `String key); ("state", mesi_to_yojson state)]
