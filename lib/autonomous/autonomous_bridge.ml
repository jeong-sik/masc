(* Autonomous_bridge — Cycle 22 / Tier A4.
   See autonomous_bridge.mli for the cooperation-contract rationale. *)

module State = Autonomous_state
module Phase = Autonomous_phase
module Outcome = Shared_types.Resilience_outcome

(* ── Phantom witness ───────────────────────────────────────────── *)

type running_valid = Running_witness

module Witness = struct
  let running_witness = Running_witness
end

(* ── The bridge value ──────────────────────────────────────────── *)

type t = {
  state : State.t;
  iteration_count : int;
  created_at : float;
  last_tick_at : float;
}

(* ── Construction ──────────────────────────────────────────────── *)

let create (_w : running_valid) ?meta ~now () =
  let state = State.init ?meta ~now () in
  { state; iteration_count = 0; created_at = now; last_tick_at = now }

(* The unit argument keeps the OCaml convention of trailing [()]
   when optional arguments are present. The witness is consumed
   but not retained — its only purpose is the type-level gate. *)

(* ── Inspection ────────────────────────────────────────────────── *)

let current_state b = b.state
let current_phase b = State.current_phase b.state
let current_phase_string b = State.current_phase_string b.state
let iteration_count b = b.iteration_count
let created_at b = b.created_at
let last_tick_at b = b.last_tick_at

(* ── Lifecycle ─────────────────────────────────────────────────── *)

let tick b ~now =
  match State.tick b.state ~now with
  | Outcome.FullSuccess { value = state'; _ } as ok ->
      let _ = ok in
      let advanced =
        {
          state = state';
          iteration_count = b.iteration_count + 1;
          created_at = b.created_at;
          last_tick_at = now;
        }
      in
      Outcome.full
        ~value:advanced
        ~confidence:(Shared_types.Confidence.make 1.0)
        ~artifacts:[]
  | Outcome.PartialSuccess { value = state'; _ } ->
      (* State-level tick stub never produces this today, but the
         pattern is here so the compiler enforces exhaustiveness
         when B6+ wires real recovery logic. *)
      let advanced =
        {
          state = state';
          iteration_count = b.iteration_count + 1;
          created_at = b.created_at;
          last_tick_at = now;
        }
      in
      Outcome.full
        ~value:advanced
        ~confidence:(Shared_types.Confidence.make 0.5)
        ~artifacts:[]
  | Outcome.GracefulFailure { reason; _ } ->
      Outcome.graceful
        ~reason:("bridge_tick_underlying_state: " ^ reason)
        ~recovery_strategy:"Abort"
        ~confidence:(Shared_types.Confidence.make 0.0)
        ()

(* ── Persistence ───────────────────────────────────────────────── *)

let suspend b : Yojson.Safe.t =
  `Assoc
    [ ("kind", `String "autonomous_bridge.v0");
      ("iteration_count", `Int b.iteration_count);
      ("created_at", `Float b.created_at);
      ("last_tick_at", `Float b.last_tick_at);
      ("state", State.to_json b.state);
    ]

(* JSON helpers (no Yojson.Safe.Util dependency in resume to keep
   the unwrapping explicit and read-side error messages tied to
   the field name). *)
let assoc_member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let expect_field obj key =
  match assoc_member key obj with
  | Some v -> Ok v
  | None -> Error (Printf.sprintf "missing field %S" key)

let expect_string = function
  | `String s -> Ok s
  | _ -> Error "expected string"

let expect_int = function
  | `Int n -> Ok n
  | _ -> Error "expected int"

let expect_float = function
  | `Float f -> Ok f
  | `Int n -> Ok (float_of_int n) (* tolerate whole-number floats *)
  | _ -> Error "expected float"

let ( let* ) = Result.bind

let resume (_w : running_valid) (json : Yojson.Safe.t) ~now =
  let _ = now in
  let* kind_json = expect_field json "kind" in
  let* kind = expect_string kind_json in
  if kind <> "autonomous_bridge.v0" then
    Error
      (Printf.sprintf "unexpected kind %S (expected autonomous_bridge.v0)" kind)
  else
    let* iter_json = expect_field json "iteration_count" in
    let* iter = expect_int iter_json in
    let* created_json = expect_field json "created_at" in
    let* created = expect_float created_json in
    let* last_json = expect_field json "last_tick_at" in
    let* last = expect_float last_json in
    let* state_json = expect_field json "state" in
    (* Stub: rebuild Autonomous_state in Idle, preserving the meta
       payload if one was carried through suspend. The full restore
       awaits Autonomous_state.of_json (later Tier). *)
    let meta =
      match assoc_member "ctx" state_json with
      | Some (`Assoc _ as ctx) -> (
          match assoc_member "meta" ctx with
          | Some m -> m
          | None -> `Null)
      | _ -> `Null
    in
    let state = State.init ~meta ~now:created () in
    Ok
      {
        state;
        iteration_count = iter;
        created_at = created;
        last_tick_at = last;
      }
