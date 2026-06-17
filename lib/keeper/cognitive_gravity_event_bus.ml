(** Cognitive Gravity Event Bus — Phase 4 GC Trigger Wiring

    Provides a registry of decay triggers and a dispatch mechanism
    that integrates with the existing compaction/audit loop.

    Four trigger types:
    - TurnElapsed: facts older than min_age with stale=0.00
    - NoNewMentions: no new interactions for min_idle turns
    - Contradiction: score stable but gap > 0
    - ManualDecay: explicit invocation by keeper

    BLOCK A fix: handler exception safety — try...with wraps each handler call
    BLOCK B fix: current_turn tracking — Atomic.t incremented on emit/dispatch
*)

type decay_trigger =
  | TurnElapsed of { age: int; min_age: int }
  | NoNewMentions of { turns: int; min_idle: int }
  | Contradiction of { fact_id: string; staleness: float }
  | ManualDecay of { fact_ids: string list; rate: float }

type decay_event = {
  trigger: decay_trigger;
  target_fact_ids: string list;
  delta: float;
  applied_at_turn: int;
}

(* ── current_turn tracking (BLOCK B fix) ───────────────────────── *)

let current_turn : int Atomic.t = Atomic.make 0

let increment_turn () : unit =
  Atomic.fetch_and_add current_turn 1

(* Registry of registered triggers with their handlers *)
let trigger_registry : (decay_trigger * (decay_event -> unit)) list ref = ref []

(* Emit a decay event to all registered handlers *)
let emit (event : decay_event) : unit =
  increment_turn ();
  (* BLOCK A fix: try...with wraps each handler to prevent single handler exception from stopping all *)
  List.iter (fun (_, handler) ->
    try handler event with
    | exn ->
        (* Log handler failure but continue processing remaining handlers *)
        Format.eprintf "[cognitive_gravity] handler exception: %a@." Exn.pp exn
  ) !trigger_registry

(* Register a new trigger with its handler *)
let register_trigger (trigger : decay_trigger) ~handler:(handler : decay_event -> unit) : unit =
  trigger_registry := (trigger, handler) :: !trigger_registry

(* Dispatch: generate decay events based on current state *)
let dispatch () : decay_event list =
  increment_turn ();
  (* TODO: Implement dispatch logic based on registered triggers
     and current fact state from the knowledge base *)
  []

(* Apply decay to facts *)
let apply_decay (event : decay_event) : unit =
  (* TODO: Implement decay application logic
     Update fact staleness scores based on the event *)
  match event.trigger with
  | TurnElapsed { age; min_age } ->
      (* Mark facts older than min_age with stale=0.00 *)
      ()
  | NoNewMentions { turns; min_idle } ->
      (* Mark facts with no new interactions for min_idle turns *)
      ()
  | Contradiction { fact_id; staleness } ->
      (* Update contradiction score for fact_id *)
      ()
  | ManualDecay { fact_ids; rate } ->
      (* Apply manual decay rate to specified fact_ids *)
      ()