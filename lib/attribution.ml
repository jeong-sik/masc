(** See [Attribution.mli] for documentation. *)

type origin = Det | NonDet

let string_of_origin = function Det -> "det" | NonDet -> "nondet"

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
