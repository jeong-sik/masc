(** Cognitive Gravity Event Bus — Phase4 GC trigger registry + dispatch.
    See .mli for public API docs. *)

type decay_trigger =
  | TurnElapsed of { age : int; min_age : int }
  | NoNewMentions of { turns : int; min_idle : int }
  | Contradiction of { fact_id : string; staleness : float }
  | ManualDecay of { fact_ids : string list; rate : float }

type decay_event = {
  trigger : decay_trigger;
  target_fact_ids : string list;
  delta : float;
  applied_at_turn : int;
}

(* ── Equality for Hashtbl keys ─────────────────────────────────── *)

let equal_decay_trigger a b =
  match a, b with
  | TurnElapsed { age = a1; min_age = m1 }, TurnElapsed { age = a2; min_age = m2 } ->
    a1 = a2 && m1 = m2
  | NoNewMentions { turns = t1; min_idle = i1 }, NoNewMentions { turns = t2; min_idle = i2 } ->
    t1 = t2 && i1 = i2
  | Contradiction { fact_id = f1; staleness = s1 }, Contradiction { fact_id = f2; staleness = s2 } ->
    String.equal f1 f2 && s1 = s2
  | ManualDecay { fact_ids = ids1; rate = r1 }, ManualDecay { fact_ids = ids2; rate = r2 } ->
    r1 = r2 && List.length ids1 = List.length ids2 && List.for_all2 String.equal ids1 ids2
  | _ -> false

let hash_decay_trigger = function
  | TurnElapsed { age; min_age } -> age * 31 + min_age
  | NoNewMentions { turns; min_idle } -> turns * 31 + min_idle
  | Contradiction { fact_id; staleness = _ } -> String.length fact_id
  | ManualDecay { fact_ids = _; rate = _ } -> 0

(* ── Registry state (mutable, module-level) ───────────────────── *)

type handler = decay_event -> unit

let registry : (decay_trigger, handler list) Hashtbl.t =
  Hashtbl.create ~random:false 16

(* ── Default deltas ────────────────────────────────────────────── *)

let default_delta = function
  | TurnElapsed _ -> 0.02
  | NoNewMentions _ -> 0.05
  | Contradiction _ -> 0.10
  | ManualDecay { rate; _ } -> rate

(* ── Default target selectors ──────────────────────────────────── *)

let default_target_fact_ids = function
  | TurnElapsed _ -> []
  | NoNewMentions _ -> []
  | Contradiction { fact_id; _ } -> [fact_id]
  | ManualDecay { fact_ids; _ } -> fact_ids

(* ── Registry ──────────────────────────────────────────────────── *)

let register_trigger trigger ~handler =
  let current =
    match Hashtbl.find registry trigger with
    | hs -> hs
    | exception Not_found -> []
  in
  Hashtbl.replace registry trigger (handler :: current)

(* ── Dispatch ──────────────────────────────────────────────────── *)

let current_turn : int ref = ref 0

let dispatch () =
  let turn = !current_turn + 1 in
  current_turn := turn;
  let results = ref [] in
  Hashtbl.iter
    (fun trigger handlers ->
       let target_ids = default_target_fact_ids trigger in
       let delta = default_delta trigger in
       let event =
         { trigger; target_fact_ids = target_ids; delta; applied_at_turn = turn }
       in
       List.iter (fun h -> h event) handlers;
       results := event :: !results)
    registry;
  List.rev !results

(* ── Emit ──────────────────────────────────────────────────────── *)

let emit event =
  let handlers =
    match Hashtbl.find registry event.trigger with
    | hs -> hs
    | exception Not_found -> []
  in
  List.iter (fun h -> h event) handlers

(* ── Default log handler ───────────────────────────────────────── *)

let decay_event_to_json (e : decay_event) : Yojson.Safe.t =
  let trigger_json =
    match e.trigger with
    | TurnElapsed { age; min_age } ->
      `Assoc ["type", `String "TurnElapsed"; "age", `Int age; "min_age", `Int min_age]
    | NoNewMentions { turns; min_idle } ->
      `Assoc ["type", `String "NoNewMentions"; "turns", `Int turns; "min_idle", `Int min_idle]
    | Contradiction { fact_id; staleness } ->
      `Assoc ["type", `String "Contradiction"; "fact_id", `String fact_id; "staleness", `Float staleness]
    | ManualDecay { fact_ids; rate } ->
      `Assoc ["type", `String "ManualDecay"; "fact_ids", `List (List.map (fun id -> `String id) fact_ids); "rate", `Float rate]
  in
  `Assoc [
    "record_type", `String "cognitive_gravity_event";
    "trigger", trigger_json;
    "target_fact_ids", `List (List.map (fun id -> `String id) e.target_fact_ids);
    "delta", `Float e.delta;
    "applied_at_turn", `Int e.applied_at_turn;
  ]

let default_log_handler base_path event =
  let dir = Filename.concat base_path "data/cognitive-gravity-events" in
  (try Unix.mkdir_p dir with _ -> ());
  let line = Yojson.Safe.to_string ~std:true (decay_event_to_json event) in
  try
    let now = Unix.gettimeofday () in
    let date_str = Filename.concat dir (Printf.sprintf "events-%s.jsonl"
      (try
         let tm = Unix.localtime now in
         Printf.sprintf "%04d-%02d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
       with _ -> "unknown"))
    in
    let oc = open_out_gen [Open_append; Open_creat; Open_text] 0o644 date_str in
    try
      output_string oc (line ^ "\n");
      close_out oc
    with exn ->
      close_out_noerr oc;
      Printf.eprintf "cognitive_gravity_event_bus: write error %s\n%!" (Printexc.to_string exn)
  with exn ->
    Printf.eprintf "cognitive_gravity_event_bus: log error %s\n%!" (Printexc.to_string exn)

(* ── Default triggers ──────────────────────────────────────────── *)

module Default_triggers = struct
  let setup ~store_base_path =
    let log_handler = default_log_handler store_base_path in
    register_trigger (TurnElapsed { age = 0; min_age = 3 }) ~handler:log_handler;
    register_trigger (NoNewMentions { turns = 0; min_idle = 5 }) ~handler:log_handler;
    register_trigger (Contradiction { fact_id = ""; staleness = 0.3 }) ~handler:log_handler
end

(* ── run_gc ────────────────────────────────────────────────────── *)

let run_gc ~base_path =
  let events = dispatch () in
  (* Each dispatch event already called its registered handlers.
     We additionally run the default_log_handler for any event that
     doesn't yet have one, so unregistered triggers still get logged. *)
  List.iter (fun evt ->
    match Hashtbl.find registry evt.trigger with
    | _ -> ()
    | exception Not_found -> default_log_handler base_path evt
  ) events