(** Keeper Decision Audit — Forensics-only decision trail.

    Abstract record prevents trust calculations from consuming
    forensics data. Ring buffer + periodic JSONL flush.

    @since Decision Layer v2 — Phase A2 (#6232) *)

(* ================================================================ *)
(* Feature flag                                                     *)
(* ================================================================ *)

let decision_layer_level () =
  Env_config_core.get_int ~default:0 "MASC_DECISION_LAYER_LEVEL"

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
}

let make ~cycle_id ~keeper_name ~generation ?snapshot
    ~heartbeat_verdict ~turn_verdict ~wall_clock () =
  { cycle_id; keeper_name; generation; snapshot;
    heartbeat_verdict; turn_verdict; wall_clock }

(* ================================================================ *)
(* Serialization                                                    *)
(* ================================================================ *)

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
  ]

(* ================================================================ *)
(* Ring buffer                                                      *)
(* ================================================================ *)

let ring_capacity () =
  Env_config_core.get_int ~default:50 "MASC_DECISION_AUDIT_RING_CAPACITY"

type ring = {
  buf : decision_record option array;
  mutable pos : int;
  mutable count : int;
  mutable unflushed : int;
  mutable last_flush_ts : float;
}

let rings : (string, ring) Hashtbl.t = Hashtbl.create 8

let flush_interval_sec () =
  Env_config_core.get_float ~default:60.0 "MASC_DECISION_AUDIT_FLUSH_INTERVAL_SEC"

let flush_batch_size () =
  Env_config_core.get_int ~default:10 "MASC_DECISION_AUDIT_FLUSH_BATCH_SIZE"

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
    ring.pos <- ring.pos + 1;
    ring.count <- ring.count + 1;
    ring.unflushed <- ring.unflushed + 1
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
        let dir =
          let open Unix in
          let tm = localtime now in
          Printf.sprintf "%s/.masc/decision_audit/%s/%04d-%02d/%02d.jsonl"
            base_path keeper_name
            (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
        in
        (* Ensure parent directory exists *)
        let parent = Filename.dirname dir in
        (try Fs_compat.mkdir_p parent with _ -> ());
        (* Append unflushed records *)
        let cap = Array.length ring.buf in
        let start = ((ring.pos - ring.unflushed) mod cap + cap) mod cap in
        let oc =
          try Some (open_out_gen [Open_append; Open_creat; Open_text] 0o644 dir)
          with e ->
            Log.Keeper.warn "decision_audit flush failed: %s" (Printexc.to_string e);
            None
        in
        (match oc with
         | None -> ()
         | Some oc ->
           Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
             for i = 0 to ring.unflushed - 1 do
               let idx = (start + i) mod cap in
               match ring.buf.(idx) with
               | Some r ->
                 output_string oc (Yojson.Safe.to_string (to_json r));
                 output_char oc '\n'
               | None -> ()
             done));
        ring.unflushed <- 0;
        ring.last_flush_ts <- now
      end
