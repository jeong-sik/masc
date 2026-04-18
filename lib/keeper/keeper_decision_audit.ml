(** Keeper Decision Audit — Forensics-only decision trail.

    Abstract record prevents trust calculations from consuming
    forensics data. Ring buffer + periodic JSONL flush.

    @since Decision Layer v2 — Phase A2 (#6232) *)

(* ================================================================ *)
(* Feature flag                                                     *)
(* ================================================================ *)

(* These values are read from tests and module-init code that can run before an
   Eio scheduler exists, so they cannot depend on Eio.Lazy.  Use a
   cross-context Atomic+Stdlib.Mutex memo rather than Stdlib.Lazy.force. *)
let resolve_cached cache mu compute =
  match Atomic.get cache with
  | Some value -> value
  | None ->
      Mutex.protect mu (fun () ->
        match Atomic.get cache with
        | Some value -> value
        | None ->
            let value = compute () in
            Atomic.set cache (Some value);
            value)

let decision_layer_level_cached : int option Atomic.t = Atomic.make None
let decision_layer_level_mu = Mutex.create ()

let decision_layer_level () =
  resolve_cached decision_layer_level_cached decision_layer_level_mu
    (fun () -> Env_config_core.get_int ~default:0 "MASC_DECISION_LAYER_LEVEL")

let audit_enabled () = decision_layer_level () >= 1

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type decision_record = {
  cycle_id : string;
  keeper_name : string;
  generation : int;
  snapshot : Keeper_measurement.measurement_snapshot option;
  heartbeat_verdict : Heartbeat_smart.decision;
  turn_verdict : Keeper_world_observation.turn_verdict;
  wall_clock : float;
  tool_diversity_entropy : float option;
}

let make ~cycle_id ~keeper_name ~generation ?snapshot
    ~heartbeat_verdict ~turn_verdict ~wall_clock
    ?tool_diversity_entropy () =
  { cycle_id; keeper_name; generation; snapshot;
    heartbeat_verdict; turn_verdict; wall_clock;
    tool_diversity_entropy }

(* ================================================================ *)
(* Serialization                                                    *)
(* ================================================================ *)

(* Simplified tags for JSONL audit keys — intentionally differs from
   Heartbeat_smart.decision_to_string which uses colon-separated format
   with timing data ("skip:busy", "skip:idle(next in 3.2s)"). *)
let heartbeat_verdict_to_string = function
  | Heartbeat_smart.Emit -> "emit"
  | Heartbeat_smart.Skip_busy -> "skip_busy"
  | Heartbeat_smart.Skip_idle _ -> "skip_idle"

let to_json (r : decision_record) : Yojson.Safe.t =
  `Assoc [
    "cycle_id", `String r.cycle_id;
    "keeper_name", `String r.keeper_name;
    "generation", `Int r.generation;
    "snapshot", (match r.snapshot with
      | Some s -> Keeper_measurement.measurement_snapshot_to_json s
      | None -> `Null);
    "heartbeat_verdict", `String (heartbeat_verdict_to_string r.heartbeat_verdict);
    "turn_verdict", `String
      (match r.turn_verdict with
       | Keeper_world_observation.Run _ -> "run"
       | Keeper_world_observation.Skip _ -> "skip");
    "turn_reasons", `List
      (List.map (fun s -> `String s)
         (Keeper_world_observation.verdict_reasons_to_strings r.turn_verdict));
    "wall_clock", `Float r.wall_clock;
    "tool_diversity_entropy", (match r.tool_diversity_entropy with
      | Some e -> `Float e
      | None -> `Null);
  ]

(* ================================================================ *)
(* Ring buffer                                                      *)
(* ================================================================ *)

let ring_capacity_cached : int option Atomic.t = Atomic.make None
let ring_capacity_mu = Mutex.create ()

let ring_capacity () =
  max 1
    (resolve_cached ring_capacity_cached ring_capacity_mu (fun () ->
         Env_config_core.get_int ~default:50
           "MASC_DECISION_AUDIT_RING_CAPACITY"))

type ring = {
  buf : decision_record option array;
  mutable pos : int;
  mutable count : int;
  mutable unflushed : int;
  mutable last_flush_ts : float;
}

let rings : (string, ring) Hashtbl.t = Hashtbl.create 8

let flush_interval_sec () = 60.0

let flush_batch_size () = 10

let get_or_create_ring name =
  match Hashtbl.find_opt rings name with
  | Some r -> r
  | None ->
    let cap = ring_capacity () in
    let r = { buf = Array.make cap None; pos = 0; count = 0;
              unflushed = 0; last_flush_ts = Time_compat.now () } in
    Hashtbl.replace rings name r;
    r

let append ~keeper_name (rec_ : decision_record) =
  if not (audit_enabled ()) then ()
  else begin
    let ring = get_or_create_ring keeper_name in
    let cap = Array.length ring.buf in
    ring.buf.(ring.pos mod cap) <- Some rec_;
    ring.pos <- (ring.pos + 1) mod cap;
    ring.count <- min (ring.count + 1) cap;
    ring.unflushed <- min (ring.unflushed + 1) cap
  end

let recent ~keeper_name ~limit : decision_record list =
  match Hashtbl.find_opt rings keeper_name with
  | None -> []
  | Some ring ->
    let cap = Array.length ring.buf in
    let n = min limit (min ring.count cap) in
    let result = ref [] in
    for i = 0 to n - 1 do
      let idx = ((ring.pos - 1 - i) mod cap + cap) mod cap in
      match ring.buf.(idx) with
      | Some r -> result := r :: !result
      | None -> ()
    done;
    List.rev !result

(* ================================================================ *)
(* JSONL flush                                                      *)
(* ================================================================ *)

let flush_if_needed ~base_path ~keeper_name =
  if not (audit_enabled ()) then ()
  else
    match Hashtbl.find_opt rings keeper_name with
    | None -> ()
    | Some ring ->
      let now = Time_compat.now () in
      let should_flush =
        ring.unflushed >= flush_batch_size ()
        || (ring.unflushed > 0
            && now -. ring.last_flush_ts >= flush_interval_sec ())
      in
      if not should_flush then ()
      else begin
        let safe_name = Keeper_alerting_path.sanitize_keeper_name keeper_name in
        let dir =
          let open Unix in
          let tm = localtime now in
          Printf.sprintf "%s/.masc/decision_audit/%s/%04d-%02d/%02d.jsonl"
            base_path safe_name
            (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
        in
        let parent = Filename.dirname dir in
        Safe_ops.protect ~default:() (fun () -> Fs_compat.mkdir_p parent);
        let cap = Array.length ring.buf in
        let start = ((ring.pos - ring.unflushed) mod cap + cap) mod cap in
        let flush_lines =
          let rec gather i acc =
            if i >= ring.unflushed then List.rev acc
            else
              let idx = (start + i) mod cap in
              match ring.buf.(idx) with
              | Some r -> gather (i + 1) ((Yojson.Safe.to_string (to_json r) ^ "\n") :: acc)
              | None -> gather (i + 1) acc
          in
          String.concat "" (gather 0 [])
        in
        (try
          Fs_compat.append_file dir flush_lines;
          ring.unflushed <- 0
        with Eio.Cancel.Cancelled _ as e -> raise e
           | e -> Log.Keeper.warn "decision_audit flush failed: %s" (Printexc.to_string e));
        ring.last_flush_ts <- now
      end

(* ================================================================ *)
(* Decision Pipeline Mermaid diagram                               *)
(* ================================================================ *)

let decision_pipeline_to_mermaid
    ?(guard_penalty_total : int option)
    ?(tool_policy_mode : [`Preset of string | `Custom] option)
    ?(turn_outcome : [`Ok | `Failed] option)
    ~(phase : Keeper_state_machine.phase)
    ~(thompson_alpha : float)
    ~(thompson_beta : float)
    ~(tool_count : int)
    ~(recovery_floor_count : int)
    ()
    : string =
  let b = Buffer.create 512 in
  let p fmt = Printf.bprintf b fmt in
  let level = decision_layer_level () in
  let score =
    if thompson_alpha +. thompson_beta > 0.0
    then thompson_alpha /. (thompson_alpha +. thompson_beta)
    else 0.5
  in
  p "stateDiagram-v2\n";
  p "    state Running {\n";
  p "        [*] --> NormalOps\n";
  p "        NormalOps --> GuardFires: guardrail_stop\n";
  p "        GuardFires --> ThompsonPenalty: beta += 0.5\n";
  p "        ThompsonPenalty --> NormalOps: cap 1/cycle\n";
  p "    }\n";
  p "    state Failing {\n";
  p "        [*] --> ToolRestricted\n";
  p "        ToolRestricted --> TurnAttempt: recovery floor (%d tools)\n"
    recovery_floor_count;
  p "        TurnAttempt --> TurnAttempt: turn fails\n";
  p "        TurnAttempt --> RecoveryReady: turn succeeds\n";
  p "    }\n";
  p "    Running --> Failing: consecutive failures\n";
  p "    Failing --> Running: heartbeat_ok\n";
  p "    Running --> Running: shard restored\n";
  p "\n";
  p "    classDef active fill:#22c55e,stroke:#16a34a,color:#fff,stroke-width:3px\n";
  p "    classDef warn fill:#f59e0b,stroke:#d97706,color:#fff,stroke-width:3px\n";
  p "    classDef off fill:#6b7280,stroke:#4b5563,color:#fff\n";
  (match phase with
   | Keeper_state_machine.Running ->
     p "    class Running active\n"
   | Keeper_state_machine.Failing ->
     p "    class Failing warn\n"
   | _ ->
     p "    class Running off\n";
     p "    class Failing off\n");
  p "\n";
  let penalty_str = match guard_penalty_total with
    | Some n -> string_of_int n
    | None -> "n/a"
  in
  let policy_str = match tool_policy_mode with
    | Some (`Preset name) -> Printf.sprintf "preset:%s" name
    | Some `Custom -> "custom"
    | None -> "n/a"
  in
  let outcome_str = match turn_outcome with
    | Some `Ok -> "ok"
    | Some `Failed -> "failed"
    | None -> "n/a"
  in
  p "    note right of Running\n";
  p "      Thompson: %.2f (α=%.1f β=%.1f)\n" score thompson_alpha thompson_beta;
  p "      Tools: %d / floor %d\n" tool_count recovery_floor_count;
  p "      Level: %d\n" level;
  p "      Guard pen this cycle: %s\n" penalty_str;
  p "      Tool policy: %s\n" policy_str;
  p "      Turn outcome: %s\n" outcome_str;
  p "    end note\n";
  Buffer.contents b

(* ================================================================ *)
(* Cascade FSM Mermaid diagram                                      *)
(* ================================================================ *)

type unhealthy_reason =
  [ `Saturated
  | `Unreachable
  | `Rate_limited
  | `Timeout
  | `Other of string
  ]

type provider_health =
  [ `Healthy
  | `Unhealthy of unhealthy_reason
  | `Unknown
  ]

let sanitize_mermaid_note s =
  String.map (fun c ->
    if c = ':' || c = '\n' || c = '\r' then ' ' else c) s

let unhealthy_reason_label = function
  | `Saturated -> "saturated"
  | `Unreachable -> "unreachable"
  | `Rate_limited -> "rate_limited"
  | `Timeout -> "timeout"
  | `Other s -> sanitize_mermaid_note s

let cascade_fsm_to_mermaid
    ?(provider_health : (string * provider_health) list option)
    ?(slot_state : (int * int) option)
    ?(effective_cascade_reason : string option)
    ~(models : string list)
    ~(last_provider_result : string option)
    ()
    : string =
  let b = Buffer.create 512 in
  let p fmt = Printf.bprintf b fmt in
  (* Look up provider health by label (mirrors CascadeLiveness.tla phealth). *)
  let health_for label =
    match provider_health with
    | None -> `Unknown
    | Some pairs ->
      (try List.assoc label pairs with Not_found -> `Unknown)
  in
  p "stateDiagram-v2\n";
  p "    [*] --> SelectProvider: AdmitKeeper\n";
  (* Provider nodes *)
  let n = List.length models in
  List.iteri (fun i label ->
    let is_last = (i = n - 1) in
    let try_edge = if is_last then "TryLast" else "TryNonLast" in
    if i = 0 then
      p "    SelectProvider --> P%d: %s\n" i try_edge
    else
      p "    P%d --> P%d: CascadableError\n" (i - 1) i;
    p "    state \"%s\" as P%d\n" label i;
    p "    P%d --> Accept: RespondOk\n" i;
    if not is_last then begin
      p "    P%d --> P%d: SlotUnavailable\n" i (i + 1)
    end else begin
      p "    P%d --> AcceptExhaust: LastProviderFail\\n(accept_on_exhaustion)\n" i;
      p "    P%d --> Exhausted: LastProviderFail\n" i
    end
  ) models;
  p "    Accept --> [*]\n";
  p "    AcceptExhaust --> [*]\n";
  p "    Exhausted --> [*]\n";
  p "\n";
  p "    classDef ok fill:#22c55e,stroke:#16a34a,color:#fff,stroke-width:3px\n";
  p "    classDef warn fill:#f59e0b,stroke:#d97706,color:#fff,stroke-width:3px\n";
  p "    classDef err fill:#ef4444,stroke:#dc2626,color:#fff,stroke-width:3px\n";
  p "    classDef dim fill:#6b7280,stroke:#4b5563,color:#fff\n";
  p "    class Accept ok\n";
  p "    class AcceptExhaust warn\n";
  p "    class Exhausted err\n";
  (* Provider health styling: unhealthy providers get warn class and
     a note listing the typed reason (Saturated/Unreachable/...) so
     the operator sees *why* the provider is marked down. *)
  List.iteri (fun i label ->
    match health_for label with
    | `Unhealthy reason ->
      p "    class P%d warn\n" i;
      p "    note right of P%d: unhealthy: %s\n" i
        (unhealthy_reason_label reason)
    | `Unknown -> p "    class P%d dim\n" i
    | `Healthy -> ()
  ) models;
  (* Highlight last result provider (overrides health styling). *)
  (match last_provider_result with
   | Some r when String.length r > 0 ->
     List.iteri (fun i label ->
       if label = r then
         p "    class P%d ok\n" i
     ) models
   | _ -> ());
  p "\n";
  p "    note right of SelectProvider\n";
  p "      Models: %d\n" n;
  p "      Order: %s\n" (String.concat " > " models);
  (match slot_state with
   | Some (used, max) -> p "      Slots: %d / %d\n" used max
   | None -> ());
  (match effective_cascade_reason with
   | Some r when String.length r > 0 -> p "      Reason: %s\n" r
   | _ -> ());
  p "    end note\n";
  Buffer.contents b
