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

(* --- Deserialization --- *)

let outcome_of_yojson (json : Yojson.Safe.t) : (outcome, string) result =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "kind" fields with
      | Some (`String "passed") -> Ok Passed
      | Some (`String "policy_failed") -> (
          match List.assoc_opt "reason" fields with
          | Some (`String reason) -> Ok (Policy_failed { reason })
          | _ -> Error "Policy_failed: missing reason")
      | Some (`String "transition_blocked") -> (
          match
            ( List.assoc_opt "from_state" fields,
              List.assoc_opt "to_state" fields,
              List.assoc_opt "reason" fields )
          with
          | Some (`String from_state), Some (`String to_state), Some (`String reason) ->
              Ok (Transition_blocked { from_state; to_state; reason })
          | _ -> Error "Transition_blocked: missing fields")
      | Some (`String "partial_pass") -> (
          match
            (List.assoc_opt "score" fields, List.assoc_opt "rationale" fields)
          with
          | Some (`Float score), Some (`String rationale) ->
              Ok (Partial_pass { score; rationale })
          | Some (`Int score), Some (`String rationale) ->
              Ok (Partial_pass { score = float_of_int score; rationale })
          | _ -> Error "Partial_pass: missing fields")
      | _ -> Error "outcome: missing or invalid kind")
  | _ -> Error "outcome: expected object"

let of_yojson (json : Yojson.Safe.t) : (t, string) result =
  match json with
  | `Assoc fields -> (
      match
        ( List.assoc_opt "origin" fields,
          List.assoc_opt "gate" fields,
          List.assoc_opt "evidence" fields,
          List.assoc_opt "outcome" fields )
      with
      | ( Some (`String origin_str),
          Some (`String gate),
          Some evidence,
          Some outcome_json ) -> (
          match origin_str with
          | "det" -> (
              match outcome_of_yojson outcome_json with
              | Ok outcome -> Ok { origin = Det; gate; evidence; outcome }
              | Error e -> Error e)
          | "nondet" -> (
              match outcome_of_yojson outcome_json with
              | Ok outcome -> Ok { origin = NonDet; gate; evidence; outcome }
              | Error e -> Error e)
          | s -> Error ("invalid origin: " ^ s))
      | _ -> Error "missing required fields")
  | _ -> Error "expected JSON object"

(* --- Debug representation --- *)

let show (t : t) : string =
  Printf.sprintf "Attribution{origin=%s; gate=%s; outcome=%s}"
    (string_of_origin t.origin)
    t.gate
    (match t.outcome with
     | Passed -> "Passed"
     | Policy_failed _ -> "Policy_failed{...}"
     | Transition_blocked _ -> "Transition_blocked{...}"
     | Partial_pass _ -> "Partial_pass{...}")

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
