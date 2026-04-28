(* Autonomous_state — pure state value for the autonomous loop.
   Cycle 21 / Tier B4. See autonomous_state.mli for the design rationale. *)

module Phase = Autonomous_phase
module Outcome = Shared_types.Resilience_outcome
module Confidence = Shared_types.Confidence

(* ── Phase-indexed context ──────────────────────────────────────── *)

type 'phase ctx =
  | Idle_ctx : {
      created_at : float;
      meta : Yojson.Safe.t;
    }
      -> Phase.idle ctx
  | Perceiving_ctx : Phase.perceiving ctx
  | Intending_ctx : Phase.intending ctx
  | Planning_ctx : Phase.planning ctx
  | Executing_ctx : Phase.executing ctx
  | Verifying_ctx : Phase.verifying ctx
  | Reflecting_ctx : Phase.reflecting ctx
  | Adapting_ctx : Phase.adapting ctx

(* ── Existential packings ──────────────────────────────────────── *)

type phase_packed = Packed_phase : 'a Phase.any -> phase_packed

type ctx_packed = Packed_ctx : 'a ctx -> ctx_packed

(* ── The state record ──────────────────────────────────────────── *)

type t = {
  phase : phase_packed;
  ctx : ctx_packed;
  iteration_count : int;
  created_at : float;
  last_tick_at : float;
}

(* ── Construction ──────────────────────────────────────────────── *)

let init ?(meta = `Null) ~now () =
  let idle_ctx = Idle_ctx { created_at = now; meta } in
  {
    phase = Packed_phase Phase.Any_idle;
    ctx = Packed_ctx idle_ctx;
    iteration_count = 0;
    created_at = now;
    last_tick_at = now;
  }

(* ── Inspection ────────────────────────────────────────────────── *)

let current_phase t =
  match t.phase with Packed_phase any -> Phase.any_to_tag any

let current_phase_string t =
  match t.phase with Packed_phase any -> Phase.any_to_string any

let iteration_count t = t.iteration_count
let created_at t = t.created_at
let last_tick_at t = t.last_tick_at

(* ── Lifecycle ─────────────────────────────────────────────────── *)

let tick t ~now =
  let advanced =
    {
      t with
      iteration_count = t.iteration_count + 1;
      last_tick_at = now;
    }
  in
  Outcome.full
    ~value:advanced
    ~confidence:(Confidence.make 1.0)
    ~artifacts:[]

(* ── Serialisation ─────────────────────────────────────────────── *)

(* Project the existential ctx to its JSON representation. Only
   Idle_ctx carries actual payload at this Tier; the other seven
   stub constructors render as the empty object. The [type a.]
   annotation is required so the GADT match accepts the eight
   different phantom indices uniformly. *)
let ctx_to_json : type a. a ctx -> Yojson.Safe.t = function
  | Idle_ctx { created_at; meta } ->
      `Assoc
        [ ("created_at", `Float created_at); ("meta", meta) ]
  | Perceiving_ctx -> `Assoc []
  | Intending_ctx -> `Assoc []
  | Planning_ctx -> `Assoc []
  | Executing_ctx -> `Assoc []
  | Verifying_ctx -> `Assoc []
  | Reflecting_ctx -> `Assoc []
  | Adapting_ctx -> `Assoc []

let to_json t =
  let ctx_json =
    match t.ctx with Packed_ctx c -> ctx_to_json c
  in
  `Assoc
    [ ("phase", `String (current_phase_string t));
      ("iteration_count", `Int t.iteration_count);
      ("created_at", `Float t.created_at);
      ("last_tick_at", `Float t.last_tick_at);
      ("ctx", ctx_json);
    ]
