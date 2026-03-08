(** Reservation_station -- Tomasulo Out-of-Order Scheduling for SWARM-RISC

    Implements per-agent Reservation Stations (RS) with dependency tracking
    via operand tags.  When a result appears on the Common Data Bus (CDB),
    all RS entries snoop it and mark matching operands as ready.  An entry
    whose operands are all ready can be issued for execution.

    Mapping to MASC:
    - CDB = masc_broadcast SSE events
    - Operand tags = micro-op IDs (string)
    - RS capacity = configurable per agent (default 8)

    Reference: Tomasulo, R.M. (1967) "An Efficient Algorithm for Exploiting
    Multiple Arithmetic Units", IBM Journal of Research and Development.

    @since 2.78.0 — Phase 3 *)

(* ================================================================ *)
(* RS Entry                                                         *)
(* ================================================================ *)

(** A single reservation station entry.  Tracks up to N operand
    dependencies via string tags. *)
type rs_entry = {
  op_id : string;
  instruction : Risc_types.instruction;
  parent_task_id : string;
  operand_tags : string list;       (** IDs of ops this entry depends on *)
  resolved : string list;           (** Tags already resolved via CDB *)
  mutable issued : bool;            (** True once dispatched to execute *)
  mutable result : Yojson.Safe.t option;  (** Filled after execution *)
  enqueued_at : float;              (** Unix timestamp *)
}

let is_ready entry =
  (not entry.issued)
  && List.for_all (fun tag -> List.mem tag entry.resolved) entry.operand_tags

let remaining_deps entry =
  List.filter (fun tag -> not (List.mem tag entry.resolved)) entry.operand_tags

(* ================================================================ *)
(* Per-Agent Reservation Station                                    *)
(* ================================================================ *)

(** Per-agent reservation station with configurable capacity. *)
type agent_rs = {
  agent_id : string;
  capacity : int;
  mutable entries : rs_entry list;  (** Newest first for LIFO owner access *)
  (* Metrics *)
  mutable total_added : int;
  mutable total_issued : int;
  mutable total_completed : int;
  mutable total_stolen : int;       (** Entries stolen by other agents *)
  mutable cdb_wakeups : int;        (** Times CDB resolved an operand *)
  mutable stall_cycles : int;       (** Cycles with no issuable entry *)
}

let create_agent_rs ?(capacity = 8) agent_id = {
  agent_id;
  capacity;
  entries = [];
  total_added = 0;
  total_issued = 0;
  total_completed = 0;
  total_stolen = 0;
  cdb_wakeups = 0;
  stall_cycles = 0;
}

(** True if the RS has room for another entry. *)
let has_capacity rs =
  List.length rs.entries < rs.capacity

(** Number of non-issued entries. *)
let pending_count rs =
  List.length (List.filter (fun e -> not e.issued) rs.entries)

(** Number of issued-but-not-completed entries. *)
let in_flight_count rs =
  List.length (List.filter (fun e -> e.issued && Option.is_none e.result) rs.entries)

(* ================================================================ *)
(* RS Operations                                                    *)
(* ================================================================ *)

(** Add a new entry to the reservation station.  Returns Error if full. *)
let add_entry rs ~op_id ~instruction ~parent_task_id ~operand_tags =
  if not (has_capacity rs) then
    Error "Reservation station full"
  else begin
    (* Tags that are already completed (self-resolved) are pre-resolved *)
    let completed_ops = List.filter_map (fun e ->
      if Option.is_some e.result then Some e.op_id else None
    ) rs.entries in
    let resolved = List.filter (fun tag -> List.mem tag completed_ops) operand_tags in
    let entry = {
      op_id;
      instruction;
      parent_task_id;
      operand_tags;
      resolved;
      issued = false;
      result = None;
      enqueued_at = Unix.gettimeofday ();
    } in
    rs.entries <- entry :: rs.entries;
    rs.total_added <- rs.total_added + 1;
    Ok entry
  end

(** Broadcast a CDB result: resolve matching operand tags across all entries.
    Returns the number of entries that became newly ready. *)
let cdb_broadcast rs ~completed_op_id ~result:_ =
  let newly_ready = ref 0 in
  rs.entries <- List.map (fun entry ->
    if entry.issued || Option.is_some entry.result then entry
    else if List.mem completed_op_id entry.operand_tags
            && not (List.mem completed_op_id entry.resolved) then begin
      rs.cdb_wakeups <- rs.cdb_wakeups + 1;
      let new_resolved = completed_op_id :: entry.resolved in
      let new_entry = { entry with resolved = new_resolved } in
      if is_ready new_entry then incr newly_ready;
      new_entry
    end else entry
  ) rs.entries;
  !newly_ready

(** Try to issue the oldest ready entry (FIFO among ready entries).
    Returns the entry if successful, None if nothing is ready. *)
let try_issue rs =
  (* Find oldest ready entry (entries are newest-first, so reverse search) *)
  let ready = List.filter is_ready rs.entries in
  match List.rev ready with
  | [] ->
      rs.stall_cycles <- rs.stall_cycles + 1;
      None
  | oldest :: _ ->
      oldest.issued <- true;
      rs.total_issued <- rs.total_issued + 1;
      Some oldest

(** Mark an issued entry as completed with a result.
    Also triggers internal CDB propagation for local dependencies. *)
let complete_entry rs ~op_id ~result =
  let found = ref false in
  rs.entries <- List.map (fun entry ->
    if entry.op_id = op_id && entry.issued then begin
      found := true;
      entry.result <- Some result;
      entry
    end else entry
  ) rs.entries;
  if !found then begin
    rs.total_completed <- rs.total_completed + 1;
    (* Internal CDB: propagate to other entries in same RS *)
    let _newly_ready = cdb_broadcast rs ~completed_op_id:op_id ~result in
    Ok ()
  end else
    Error (Printf.sprintf "Op %s not found or not issued" op_id)

(** Remove completed entries from the RS (garbage collection).
    Returns the list of removed entries. *)
let gc_completed rs =
  let completed, remaining = List.partition
    (fun e -> Option.is_some e.result) rs.entries in
  rs.entries <- remaining;
  completed

(** List all ready-but-not-issued entries (steal candidates). *)
let list_stealable rs =
  List.filter is_ready rs.entries

(** Remove a specific entry from the RS (for work stealing).
    Returns the entry if found and removed. *)
let steal_entry rs ~op_id =
  let found = ref None in
  rs.entries <- List.filter (fun entry ->
    if entry.op_id = op_id && is_ready entry && not entry.issued then begin
      found := Some entry;
      rs.total_stolen <- rs.total_stolen + 1;
      false  (* remove from list *)
    end else true
  ) rs.entries;
  !found

(* ================================================================ *)
(* Global RS Scheduler                                              *)
(* ================================================================ *)

(** Global scheduler: manages per-agent reservation stations. *)
type rs_scheduler = {
  agents : (string, agent_rs) Hashtbl.t;
  mutable global_cdb_events : int;
}

let create_scheduler () = {
  agents = Hashtbl.create 16;
  global_cdb_events = 0;
}

(** Get or create an agent's RS. *)
let get_or_create_rs scheduler ~agent_id ?(capacity = 8) () =
  match Hashtbl.find_opt scheduler.agents agent_id with
  | Some rs -> rs
  | None ->
      let rs = create_agent_rs ~capacity agent_id in
      Hashtbl.replace scheduler.agents agent_id rs;
      rs

(** Broadcast a CDB event to ALL agents' reservation stations.
    This is the cross-agent dependency resolution mechanism. *)
let global_cdb_broadcast scheduler ~completed_op_id ~result =
  scheduler.global_cdb_events <- scheduler.global_cdb_events + 1;
  let total_wakeups = ref 0 in
  Hashtbl.iter (fun _agent_id rs ->
    let wakeups = cdb_broadcast rs ~completed_op_id ~result in
    total_wakeups := !total_wakeups + wakeups;
  ) scheduler.agents;
  !total_wakeups

(** Get aggregate metrics across all agents. *)
let aggregate_metrics scheduler =
  let total_added = ref 0 in
  let total_issued = ref 0 in
  let total_completed = ref 0 in
  let total_stolen = ref 0 in
  let total_wakeups = ref 0 in
  let total_stalls = ref 0 in
  let total_pending = ref 0 in
  let total_in_flight = ref 0 in
  let agent_count = ref 0 in
  Hashtbl.iter (fun _id rs ->
    incr agent_count;
    total_added := !total_added + rs.total_added;
    total_issued := !total_issued + rs.total_issued;
    total_completed := !total_completed + rs.total_completed;
    total_stolen := !total_stolen + rs.total_stolen;
    total_wakeups := !total_wakeups + rs.cdb_wakeups;
    total_stalls := !total_stalls + rs.stall_cycles;
    total_pending := !total_pending + pending_count rs;
    total_in_flight := !total_in_flight + in_flight_count rs;
  ) scheduler.agents;
  `Assoc [
    ("agent_count", `Int !agent_count);
    ("total_added", `Int !total_added);
    ("total_issued", `Int !total_issued);
    ("total_completed", `Int !total_completed);
    ("total_stolen", `Int !total_stolen);
    ("cdb_wakeups", `Int !total_wakeups);
    ("stall_cycles", `Int !total_stalls);
    ("global_cdb_events", `Int scheduler.global_cdb_events);
    ("current_pending", `Int !total_pending);
    ("current_in_flight", `Int !total_in_flight);
  ]

(* ================================================================ *)
(* JSON Serialization                                               *)
(* ================================================================ *)

let entry_to_yojson entry =
  `Assoc [
    ("op_id", `String entry.op_id);
    ("instruction", Risc_types.instruction_to_yojson entry.instruction);
    ("parent_task_id", `String entry.parent_task_id);
    ("operand_tags", `List (List.map (fun t -> `String t) entry.operand_tags));
    ("resolved", `List (List.map (fun t -> `String t) entry.resolved));
    ("remaining_deps", `List (List.map (fun t -> `String t) (remaining_deps entry)));
    ("ready", `Bool (is_ready entry));
    ("issued", `Bool entry.issued);
    ("has_result", `Bool (Option.is_some entry.result));
    ("enqueued_at", `Float entry.enqueued_at);
  ]

let agent_rs_to_yojson rs =
  `Assoc [
    ("agent_id", `String rs.agent_id);
    ("capacity", `Int rs.capacity);
    ("entry_count", `Int (List.length rs.entries));
    ("pending", `Int (pending_count rs));
    ("in_flight", `Int (in_flight_count rs));
    ("stealable", `Int (List.length (list_stealable rs)));
    ("entries", `List (List.map entry_to_yojson rs.entries));
    ("metrics", `Assoc [
      ("total_added", `Int rs.total_added);
      ("total_issued", `Int rs.total_issued);
      ("total_completed", `Int rs.total_completed);
      ("total_stolen", `Int rs.total_stolen);
      ("cdb_wakeups", `Int rs.cdb_wakeups);
      ("stall_cycles", `Int rs.stall_cycles);
    ]);
  ]
