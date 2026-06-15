(** Cognitive Gravity Event Bus — Phase4 GC Trigger Wiring.

    Implements {!Cognitive_gravity_event_bus} interface.
    Manages per-keeper decay-trigger registrations and
    dispatches GC when facts cross the stale threshold (0.7).

    Based on rondo's consolidated design (task-1282) and
    garnet's original Phase4 trigger taxonomy. *)

module KeeperMap = Map.Make (String)

type decay_trigger =
  | TurnElapsed
  | NoNewMentions
  | Contradiction
  | ManualDecay
  | KeeperVerification
  | TaskCycle
  | KnowledgeImport
  | DecayResistance

let trigger_weight = function
  | TurnElapsed        -> 0.15
  | NoNewMentions      -> 0.20
  | Contradiction      -> 0.60
  | ManualDecay        -> 0.50
  | KeeperVerification -> 0.30
  | TaskCycle          -> 0.25
  | KnowledgeImport    -> 0.20
  | DecayResistance    -> (-0.40)

type event = {
  trigger : decay_trigger;
  ts_unix : float;
  keeper_id : string;
}

type handler = event -> unit

(* ── Registry ──────────────────────────────────────────────────── *)

let registry : handler list KeeperMap.t ref = ref KeeperMap.empty
let pending : event list KeeperMap.t ref = ref KeeperMap.empty

let register_trigger keeper_id handler =
  let current =
    match KeeperMap.find_opt keeper_id !registry with
    | Some handlers -> handlers
    | None -> []
  in
  registry := KeeperMap.add keeper_id (handler :: current) !registry

(* ── Emit ──────────────────────────────────────────────────────── *)

let emit event =
  let k = event.keeper_id in
  let existing = match KeeperMap.find_opt k !pending with
    | Some evs -> evs
    | None -> []
  in
  pending := KeeperMap.add k (event :: existing) !pending;
  (* Fire registered handlers immediately *)
  match KeeperMap.find_opt k !registry with
  | Some handlers -> List.iter (fun h -> h event) handlers
  | None -> ()

(* ── Dispatch ──────────────────────────────────────────────────── *)

let dispatch keeper_id =
  let events = match KeeperMap.find_opt keeper_id !pending with
    | Some evs -> evs
    | None -> []
  in
  pending := KeeperMap.remove keeper_id !pending;
  let total = List.fold_left (fun acc e -> acc +. trigger_weight e.trigger) 0.0 events in
  (* If accumulated decay >= threshold (0.7), signal GC *)
  if total >= 0.7 then 1 else 0

(* ── Peek ──────────────────────────────────────────────────────── *)

let peek keeper_id =
  match KeeperMap.find_opt keeper_id !pending with
  | Some evs -> evs
  | None -> []

(* ── Helpers ───────────────────────────────────────────────────── *)

let make_event ~trigger ~keeper_id =
  let ts_unix = Unix.time () in
  { trigger; ts_unix; keeper_id }

let emit_trigger ~trigger ~keeper_id =
  let event = make_event ~trigger ~keeper_id in
  emit event