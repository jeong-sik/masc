(* Crew_consensus — Cycle 26 / Tier A10a.
   See crew_consensus.mli for design rationale. *)

(* ── Tally ──────────────────────────────────────────────────────── *)

type tally = {
  approve : int;
  dissent : int;
  abstain : int;
}

let empty_tally = { approve = 0; dissent = 0; abstain = 0 }

let tally_of_votes votes =
  List.fold_left
    (fun acc v ->
      match v with
      | Crew_types.Approve -> { acc with approve = acc.approve + 1 }
      | Crew_types.Dissent _ -> { acc with dissent = acc.dissent + 1 }
      | Crew_types.Abstain -> { acc with abstain = acc.abstain + 1 })
    empty_tally votes

let tally_total t = t.approve + t.dissent + t.abstain

(* ── Quorum policy ──────────────────────────────────────────────── *)

type quorum_policy = {
  min_voters : int;
  approve_threshold : float;
}

let default_policy = { min_voters = 1; approve_threshold = 0.5 }

(* ── Outcome ────────────────────────────────────────────────────── *)

type deadlock_kind =
  | Tied [@tla.symbol "tied"]
  | Below_quorum [@tla.symbol "below_quorum"]
  | All_abstain [@tla.symbol "all_abstain"]
[@@deriving tla]

let all_deadlock_kinds = [ Tied; Below_quorum; All_abstain ]

type approved = |
type rejected = |
type stalemate = |

type 'state outcome =
  | Approved : tally -> approved outcome
  | Rejected : { tally : tally; reasons : string list } -> rejected outcome
  | Stalemate : { tally : tally; kind : deadlock_kind } -> stalemate outcome

type any_outcome = Any_outcome : 'a outcome -> any_outcome

(* ── Tag mirror ─────────────────────────────────────────────────── *)

type outcome_tag =
  | Approved_tag [@tla.symbol "approved"]
  | Rejected_tag [@tla.symbol "rejected"]
  | Stalemate_tag [@tla.symbol "stalemate"]
[@@deriving tla]

let all_outcome_tags = [ Approved_tag; Rejected_tag; Stalemate_tag ]

let outcome_to_tag : type a. a outcome -> outcome_tag = function
  | Approved _ -> Approved_tag
  | Rejected _ -> Rejected_tag
  | Stalemate _ -> Stalemate_tag

let any_outcome_to_tag (Any_outcome o) = outcome_to_tag o

(* ── JSON serialisation ─────────────────────────────────────────── *)

let tally_to_json t =
  `Assoc
    [
      ("approve", `Int t.approve);
      ("dissent", `Int t.dissent);
      ("abstain", `Int t.abstain);
    ]

let deadlock_kind_to_string = function
  | Tied -> "tied"
  | Below_quorum -> "below_quorum"
  | All_abstain -> "all_abstain"

let outcome_to_json : type a. a outcome -> Yojson.Safe.t = function
  | Approved tally ->
      `Assoc
        [
          ("kind", `String "approved");
          ("tally", tally_to_json tally);
        ]
  | Rejected { tally; reasons } ->
      `Assoc
        [
          ("kind", `String "rejected");
          ("tally", tally_to_json tally);
          ( "dissent_reasons",
            `List (List.map (fun r -> `String r) reasons) );
        ]
  | Stalemate { tally; kind } ->
      `Assoc
        [
          ("kind", `String "stalemate");
          ("deadlock_kind", `String (deadlock_kind_to_string kind));
          ("tally", tally_to_json tally);
        ]

let any_outcome_to_json (Any_outcome o) = outcome_to_json o

(* ── Evaluation ─────────────────────────────────────────────────── *)

let collect_dissent_reasons votes =
  List.filter_map
    (function Crew_types.Dissent r -> Some r | _ -> None)
    votes

let evaluate ~policy votes =
  let tally = tally_of_votes votes in
  let total = tally_total tally in
  if total < policy.min_voters then
    Any_outcome (Stalemate { tally; kind = Below_quorum })
  else if tally.approve = 0 && tally.dissent = 0 then
    Any_outcome (Stalemate { tally; kind = All_abstain })
  else if tally.approve = tally.dissent && tally.approve > 0 then
    Any_outcome (Stalemate { tally; kind = Tied })
  else
    let active = tally.approve + tally.dissent in
    let approve_frac =
      if active = 0 then 0.0
      else float_of_int tally.approve /. float_of_int active
    in
    if approve_frac >= policy.approve_threshold then
      Any_outcome (Approved tally)
    else
      let reasons = collect_dissent_reasons votes in
      Any_outcome (Rejected { tally; reasons })
