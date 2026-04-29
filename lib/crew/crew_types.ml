(* Crew_types — Cycle 25 / Tier A8.
   See crew_types.mli for design rationale. *)

(* ── Persona kind ─────────────────────────────────────────────── *)

type persona_kind =
  | Analyst [@tla.symbol "analyst"]
  | Executor [@tla.symbol "executor"]
  | Scholar [@tla.symbol "scholar"]
  | Verifier [@tla.symbol "verifier"]
[@@deriving tla]

let all_persona_kinds = [ Analyst; Executor; Scholar; Verifier ]

let persona_kind_to_string = to_tla_symbol

let persona_kind_of_string_opt s =
  match String.lowercase_ascii s with
  | "analyst" -> Some Analyst
  | "executor" -> Some Executor
  | "scholar" -> Some Scholar
  | "verifier" -> Some Verifier
  | _ -> None

let persona_kind_to_json p = `String (persona_kind_to_string p)

let persona_kind_of_json = function
  | `String s -> (
      match persona_kind_of_string_opt s with
      | Some p -> Ok p
      | None -> Error (Printf.sprintf "unknown persona_kind: %s" s))
  | _ -> Error "persona_kind must be a JSON string"

(* ── Vote ─────────────────────────────────────────────────────── *)

type vote =
  | Approve
  | Dissent of string
  | Abstain

let vote_label = function
  | Approve -> "approve"
  | Dissent _ -> "dissent"
  | Abstain -> "abstain"

let vote_to_json = function
  | Approve -> `Assoc [ ("kind", `String "approve") ]
  | Dissent r ->
      `Assoc [ ("kind", `String "dissent"); ("reason", `String r) ]
  | Abstain -> `Assoc [ ("kind", `String "abstain") ]

let vote_of_json = function
  | `Assoc kv -> (
      match List.assoc_opt "kind" kv with
      | Some (`String "approve") -> Ok Approve
      | Some (`String "abstain") -> Ok Abstain
      | Some (`String "dissent") -> (
          match List.assoc_opt "reason" kv with
          | Some (`String r) -> Ok (Dissent r)
          | _ -> Error "dissent vote missing 'reason' string field")
      | Some (`String other) ->
          Error (Printf.sprintf "unknown vote kind: %s" other)
      | _ -> Error "vote missing 'kind' string field")
  | _ -> Error "vote must be a JSON object"

(* ── Council identifier ───────────────────────────────────────── *)

type council_id = string

let council_id_of_string s =
  let len = String.length s in
  if len = 0 then Error "council_id must be non-empty"
  else if len > 64 then
    Error
      (Printf.sprintf "council_id too long (%d > 64 chars)" len)
  else Ok s

let council_id_to_string s = s

let council_id_to_json s = `String s

let council_id_of_json = function
  | `String s -> council_id_of_string s
  | _ -> Error "council_id must be a JSON string"

let council_id_compare = String.compare
let council_id_equal = String.equal
