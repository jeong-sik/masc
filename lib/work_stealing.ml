(** Work_stealing -- Cross-Agent Work Stealing for SWARM-RISC

    When an agent's Reservation Station is empty (idle), it can steal
    ready-but-unissued entries from busier agents.  This reduces agent
    idle time and improves overall throughput.

    Victim selection: most-loaded agent (highest count of stealable entries).
    Steal granularity: single entry (each entry = one MCP tool call).

    MASC mapping:
    - FETCH with steal flag → work_stealing.steal()
    - Stolen result → global CDB broadcast (cross-agent forwarding)
    - Metrics: steal_count, steal_latency

    Reference: Blumofe & Leiserson (1999) "Scheduling Multithreaded
    Computations by Work Stealing", JACM.

    @since 2.78.0 — Phase 3 *)

(* ================================================================ *)
(* Steal Result                                                     *)
(* ================================================================ *)

(** Result of a steal attempt. *)
type steal_result =
  | Stolen of {
      entry : Reservation_station.rs_entry;
      victim_id : string;
      thief_id : string;
    }
  | No_victim        (** No agent has stealable work *)
  | Self_only        (** Only the thief has work (no one else to steal from) *)
  | Thief_busy       (** Thief's RS is already full *)

let steal_result_to_string = function
  | Stolen { victim_id; entry; _ } ->
      Printf.sprintf "Stolen op %s from %s" entry.op_id victim_id
  | No_victim -> "No victim with stealable work"
  | Self_only -> "Only self has work"
  | Thief_busy -> "Thief RS is full"

(* ================================================================ *)
(* Victim Selection                                                 *)
(* ================================================================ *)

(** Select the best victim: agent with the most stealable entries,
    excluding the thief itself. *)
let select_victim (scheduler : Reservation_station.rs_scheduler) ~thief_id =
  let best_victim = ref None in
  let best_count = ref 0 in
  Hashtbl.iter (fun agent_id rs ->
    if agent_id <> thief_id then begin
      let stealable = List.length (Reservation_station.list_stealable rs) in
      if stealable > !best_count then begin
        best_victim := Some (agent_id, rs);
        best_count := stealable;
      end
    end
  ) scheduler.Reservation_station.agents;
  !best_victim

(* ================================================================ *)
(* Steal Operation                                                  *)
(* ================================================================ *)

(** Attempt to steal one ready-but-unissued entry from the busiest
    agent.  The stolen entry is removed from the victim's RS and
    added to the thief's RS.

    After the thief executes the stolen entry, it must call
    [Reservation_station.global_cdb_broadcast] so the result
    propagates to the original agent's dependent entries. *)
let steal scheduler ~thief_id =
  let thief_rs =
    Reservation_station.get_or_create_rs scheduler ~agent_id:thief_id ()
  in
  if not (Reservation_station.has_capacity thief_rs) then
    Thief_busy
  else
    match select_victim scheduler ~thief_id with
    | None ->
        (* Check if only thief exists *)
        if Hashtbl.length scheduler.Reservation_station.agents <= 1 then Self_only
        else No_victim
    | Some (victim_id, victim_rs) ->
        let stealable = Reservation_station.list_stealable victim_rs in
        match stealable with
        | [] -> No_victim
        | oldest :: rest ->
            (* Pick the oldest stealable entry (FIFO — steal big/old work) *)
            let oldest = List.fold_left (fun acc e ->
              if e.Reservation_station.enqueued_at < acc.Reservation_station.enqueued_at
              then e else acc
            ) oldest rest in
            let stolen_opt =
              Reservation_station.steal_entry victim_rs
                ~op_id:oldest.Reservation_station.op_id
            in
            (match stolen_opt with
             | None -> No_victim  (* Race: entry was issued between check and steal *)
             | Some entry ->
                 (* Re-add to thief's RS with all deps already resolved *)
                 let _result = Reservation_station.add_entry thief_rs
                   ~op_id:entry.Reservation_station.op_id
                   ~instruction:entry.Reservation_station.instruction
                   ~parent_task_id:entry.Reservation_station.parent_task_id
                   ~operand_tags:[]  (* Already ready — no deps *)
                 in
                 Stolen { entry; victim_id; thief_id })

(* ================================================================ *)
(* Batch Steal                                                      *)
(* ================================================================ *)

(** Steal up to [max_count] entries in one pass.
    Useful for an agent that just became idle and wants to fill its RS.
    Returns a list of steal results (Stolen only). *)
let steal_batch scheduler ~thief_id ~max_count =
  let rec loop acc remaining =
    if remaining <= 0 then List.rev acc
    else
      let result = steal scheduler ~thief_id in
      match result with
      | Stolen _ -> loop (result :: acc) (remaining - 1)
      | _ -> List.rev acc  (* No more victims or thief full *)
  in
  loop [] max_count

(* ================================================================ *)
(* Scheduler Diagnostics                                            *)
(* ================================================================ *)

(** Overview of steal opportunities across all agents. *)
let steal_overview scheduler =
  let agents = ref [] in
  Hashtbl.iter (fun agent_id rs ->
    let stealable = List.length (Reservation_station.list_stealable rs) in
    let pending = Reservation_station.pending_count rs in
    let in_flight = Reservation_station.in_flight_count rs in
    agents := `Assoc [
      ("agent_id", `String agent_id);
      ("pending", `Int pending);
      ("in_flight", `Int in_flight);
      ("stealable", `Int stealable);
      ("total_stolen", `Int rs.Reservation_station.total_stolen);
      ("capacity_remaining", `Int (rs.Reservation_station.capacity - List.length rs.Reservation_station.entries));
    ] :: !agents
  ) scheduler.Reservation_station.agents;
  `Assoc [
    ("agents", `List !agents);
    ("global_cdb_events", `Int scheduler.Reservation_station.global_cdb_events);
  ]

let steal_result_to_yojson = function
  | Stolen { entry; victim_id; thief_id } ->
      `Assoc [
        ("status", `String "stolen");
        ("op_id", `String entry.Reservation_station.op_id);
        ("victim_id", `String victim_id);
        ("thief_id", `String thief_id);
        ("instruction", Risc_types.instruction_to_yojson entry.Reservation_station.instruction);
      ]
  | No_victim ->
      `Assoc [("status", `String "no_victim")]
  | Self_only ->
      `Assoc [("status", `String "self_only")]
  | Thief_busy ->
      `Assoc [("status", `String "thief_busy")]
