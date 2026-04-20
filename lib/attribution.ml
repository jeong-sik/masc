(** See [Attribution.mli] for documentation. *)

type origin = Det | NonDet

let string_of_origin = function Det -> "det" | NonDet -> "nondet"

let origin_of_string = function
  | "det" -> Ok Det
  | "nondet" -> Ok NonDet
  | other ->
    Error
      (Printf.sprintf
         "attribution.origin: expected \"det\" | \"nondet\", got %S" other)

type outcome =
  | Passed
  | Policy_failed of { reason : string }
  | Transition_blocked of {
      from_state : string;
      to_state : string;
      reason : string;
    }
  | Partial_pass of { score : float; rationale : string }

type t = {
  origin : origin;
  gate : string;
  evidence : Yojson.Safe.t;
  outcome : outcome;
}

(* --- Serialization --- *)

let outcome_to_yojson : outcome -> Yojson.Safe.t = function
  | Passed -> `Assoc [ ("kind", `String "passed") ]
  | Policy_failed { reason } ->
    `Assoc [ ("kind", `String "policy_failed"); ("reason", `String reason) ]
  | Transition_blocked { from_state; to_state; reason } ->
    `Assoc
      [
        ("kind", `String "transition_blocked");
        ("from_state", `String from_state);
        ("to_state", `String to_state);
        ("reason", `String reason);
      ]
  | Partial_pass { score; rationale } ->
    `Assoc
      [
        ("kind", `String "partial_pass");
        ("score", `Float score);
        ("rationale", `String rationale);
      ]

let to_yojson (t : t) : Yojson.Safe.t =
  `Assoc
    [
      ("origin", `String (string_of_origin t.origin));
      ("gate", `String t.gate);
      ("evidence", t.evidence);
      ("outcome", outcome_to_yojson t.outcome);
    ]

(* --- Parsing --- *)

open Result.Syntax

let require_field fields key =
  match List.assoc_opt key fields with
  | Some v -> Ok v
  | None -> Error (Printf.sprintf "attribution: missing field %S" key)

let require_string fields key =
  let* v = require_field fields key in
  match v with
  | `String s -> Ok s
  | other ->
    Error
      (Printf.sprintf "attribution.%s: expected string, got %s" key
         (Yojson.Safe.to_string other))

let require_float fields key =
  let* v = require_field fields key in
  match v with
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | other ->
    Error
      (Printf.sprintf "attribution.%s: expected number, got %s" key
         (Yojson.Safe.to_string other))

let outcome_of_yojson : Yojson.Safe.t -> (outcome, string) result = function
  | `Assoc fields ->
    let* kind = require_string fields "kind" in
    (match kind with
     | "passed" -> Ok Passed
     | "policy_failed" ->
       let* reason = require_string fields "reason" in
       Ok (Policy_failed { reason })
     | "transition_blocked" ->
       let* from_state = require_string fields "from_state" in
       let* to_state = require_string fields "to_state" in
       let* reason = require_string fields "reason" in
       Ok (Transition_blocked { from_state; to_state; reason })
     | "partial_pass" ->
       let* score = require_float fields "score" in
       let* rationale = require_string fields "rationale" in
       Ok (Partial_pass { score; rationale })
     | other ->
       Error
         (Printf.sprintf
            "attribution.outcome.kind: unknown %S (expected passed | \
             policy_failed | transition_blocked | partial_pass)"
            other))
  | json ->
    Error
      (Printf.sprintf "attribution.outcome: expected JSON object, got %s"
         (Yojson.Safe.to_string json))

let of_yojson = function
  | `Assoc fields ->
    let* origin_s = require_string fields "origin" in
    let* origin = origin_of_string origin_s in
    let* gate = require_string fields "gate" in
    let evidence =
      match List.assoc_opt "evidence" fields with
      | None | Some `Null -> `Null
      | Some ev -> ev
    in
    let* outcome_j = require_field fields "outcome" in
    let* outcome = outcome_of_yojson outcome_j in
    Ok { origin; gate; evidence; outcome }
  | json ->
    Error
      (Printf.sprintf "attribution: expected JSON object, got %s"
         (Yojson.Safe.to_string json))

(* --- Show --- *)

let string_of_outcome_kind = function
  | Passed -> "passed"
  | Policy_failed _ -> "policy_failed"
  | Transition_blocked _ -> "transition_blocked"
  | Partial_pass _ -> "partial_pass"

let show (t : t) : string =
  Printf.sprintf "Attribution{origin=%s; gate=%s; outcome=%s}"
    (string_of_origin t.origin) t.gate
    (string_of_outcome_kind t.outcome)

(* --- Smart constructors --- *)

let passed ~origin ~gate ~evidence = { origin; gate; evidence; outcome = Passed }

let policy_failed ~origin ~gate ~evidence ~reason =
  { origin; gate; evidence; outcome = Policy_failed { reason } }

let transition_blocked ~origin ~gate ~evidence ~from_state ~to_state ~reason =
  {
    origin;
    gate;
    evidence;
    outcome = Transition_blocked { from_state; to_state; reason };
  }

let partial_pass ~origin ~gate ~evidence ~score ~rationale =
  { origin; gate; evidence; outcome = Partial_pass { score; rationale } }
