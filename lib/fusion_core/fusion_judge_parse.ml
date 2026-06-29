(* Fusion — 심판 LLM-facing JSON → judge_synthesis (구현).
   계약/문서: fusion_judge_parse.mli, docs/rfc/RFC-0252 §7.2 *)

let ( let* ) = Result.bind

let wire_field_consensus = "consensus"
let wire_field_consensus_text = "text"
let wire_field_supporting_models = "supporting_models"
let wire_field_contradictions = "contradictions"
let wire_field_topic = "topic"
let wire_field_positions = "positions"
let wire_field_model = "model"
let wire_field_stance = "stance"
let wire_field_evidence = "evidence"
let wire_field_partial_coverage = "partial_coverage"
let wire_field_addressed_by = "addressed_by"
let wire_field_missing = "missing"
let wire_field_unique_insights = "unique_insights"
let wire_field_blind_spots = "blind_spots"
let wire_field_resolved_answer = "resolved_answer"
let wire_field_decision = "decision"
let wire_field_decision_kind = "kind"
let wire_field_answer = "answer"
let wire_decision_answer = "answer"
let wire_decision_recommend = "recommend"
let wire_decision_insufficient = "insufficient"
let wire_field_recommend_action = "action"
let wire_field_recommend_rationale = "rationale"

let expected_json_doc =
  {|Return ONLY a JSON object with this shape (no prose, no code fences):
{
  "consensus":        [ { "text": "<point most models agree on>", "supporting_models": ["<model>"] } ],
  "contradictions":   [ { "topic": "<topic>", "positions": [ { "model": "<model>", "stance": "<stance>" } ], "evidence": ["<evidence>"] } ],
  "partial_coverage": [ { "topic": "<topic>", "addressed_by": ["<model>"], "missing": "<what is missing>" } ],
  "unique_insights":  [ { "text": "<insight>", "model": "<model>" } ],
  "blind_spots":      [ "<thing no panel addressed>" ],
  "resolved_answer":  "<the single best synthesized answer>",
  "decision": { "kind": "answer", "answer": "<final answer text>" }
}
decision.kind must be one of:
  { "kind": "answer", "answer": "<text>" }
  { "kind": "recommend", "action": "<action>", "rationale": "<why>" }
  { "kind": "insufficient", "missing": ["<what the panel failed to cover>"] }
All list fields may be empty arrays. resolved_answer and decision are required.|}

(* --- JSON helpers (no exceptions; Yojson.Safe.t polymorphic variants) --- *)

let assoc_of = function
  | `Assoc kvs -> Ok kvs
  | _ -> Error "expected JSON object"

let find kvs k = List.assoc_opt k kvs

let req_string kvs k =
  match find kvs k with
  | Some (`String s) -> Ok s
  | Some _ -> Error (Printf.sprintf "field %s: expected string" k)
  | None -> Error (Printf.sprintf "missing field: %s" k)

let opt_string kvs k =
  match find kvs k with
  | Some (`String s) -> Some s
  | _ -> None

let opt_string_list kvs k =
  match find kvs k with
  | Some (`List xs) -> List.filter_map (function `String s -> Some s | _ -> None) xs
  | _ -> []

let opt_list kvs k =
  match find kvs k with
  | Some (`List xs) -> xs
  | _ -> []

(* --- tolerant element parsers (malformed element -> None, skipped) --- *)

let parse_claim : Yojson.Safe.t -> Fusion_types.claim option = function
  | `Assoc kvs ->
    (match opt_string kvs wire_field_consensus_text with
     | Some text ->
       Some
         { Fusion_types.text
         ; supporting_models = opt_string_list kvs wire_field_supporting_models
         }
     | None -> None)
  | _ -> None

let parse_position : Yojson.Safe.t -> (string * string) option = function
  | `Assoc kvs ->
    (match opt_string kvs wire_field_model, opt_string kvs wire_field_stance with
     | Some m, Some s -> Some (m, s)
     | _ -> None)
  | _ -> None

let parse_contradiction : Yojson.Safe.t -> Fusion_types.contradiction option = function
  | `Assoc kvs ->
    (match opt_string kvs wire_field_topic with
     | Some topic ->
       let positions =
         List.filter_map parse_position (opt_list kvs wire_field_positions)
       in
       Some
         { Fusion_types.topic
         ; positions
         ; evidence = opt_string_list kvs wire_field_evidence
         }
     | None -> None)
  | _ -> None

let parse_coverage : Yojson.Safe.t -> Fusion_types.coverage_gap option = function
  | `Assoc kvs ->
    (match opt_string kvs wire_field_topic with
     | Some gap_topic ->
       Some
         { Fusion_types.gap_topic
         ; addressed_by = opt_string_list kvs wire_field_addressed_by
         ; missing = opt_string kvs wire_field_missing
         }
     | None -> None)
  | _ -> None

let parse_insight : Yojson.Safe.t -> Fusion_types.insight option = function
  | `Assoc kvs ->
    (match opt_string kvs wire_field_consensus_text, opt_string kvs wire_field_model with
     | Some insight_text, Some from_model -> Some { Fusion_types.insight_text; from_model }
     | _ -> None)
  | _ -> None

(* --- decision (closed handling; unknown kind -> Error, no silent default) --- *)

let parse_decision : Yojson.Safe.t -> (Fusion_types.judge_decision, string) result = function
  | `Assoc kvs ->
    (match find kvs wire_field_decision_kind with
     | Some (`String kind) when String.equal kind wire_decision_answer ->
       let* answer = req_string kvs wire_field_answer in
       Ok (Fusion_types.Answer answer)
     | Some (`String kind) when String.equal kind wire_decision_recommend ->
       let* action = req_string kvs wire_field_recommend_action in
       let* rationale = req_string kvs wire_field_recommend_rationale in
       Ok (Fusion_types.Recommend { action; rationale })
     | Some (`String kind) when String.equal kind wire_decision_insufficient ->
       Ok
         (Fusion_types.Insufficient
            { missing_for_decision = opt_string_list kvs wire_field_missing })
     | Some (`String other) -> Error (Printf.sprintf "decision.kind unknown: %s" other)
     | Some _ -> Error "decision.kind: expected string"
     | None -> Error "decision.kind: missing")
  | _ -> Error "decision: expected object"

let of_json (j : Yojson.Safe.t) : (Fusion_types.judge_synthesis, string) result =
  let* kvs = assoc_of j in
  let* resolved_answer = req_string kvs wire_field_resolved_answer in
  let* decision =
    match find kvs wire_field_decision with
    | Some d -> parse_decision d
    | None -> Error "missing field: decision"
  in
  Ok
    { Fusion_types.consensus = List.filter_map parse_claim (opt_list kvs wire_field_consensus)
    ; contradictions =
        List.filter_map parse_contradiction (opt_list kvs wire_field_contradictions)
    ; partial_coverage =
        List.filter_map parse_coverage (opt_list kvs wire_field_partial_coverage)
    ; unique_insights =
        List.filter_map parse_insight (opt_list kvs wire_field_unique_insights)
    ; blind_spots = opt_string_list kvs wire_field_blind_spots
    ; resolved_answer
    ; decision
    }

(* 코드펜스 구분자 — 마커와 그 길이를 한 곳에 묶어 drift를 막는다. *)
let fence = "```"
let fence_len = String.length fence

(* ```json ... ``` 또는 ``` ... ``` 코드펜스를 벗긴다. *)
let strip_fences (s : string) : string =
  let s = String.trim s in
  if String.length s >= fence_len && String.equal (String.sub s 0 fence_len) fence then
    match String.index_opt s '\n' with
    | Some nl ->
      let body = String.trim (String.sub s (nl + 1) (String.length s - nl - 1)) in
      if String.length body >= fence_len
         && String.equal
              (String.sub body (String.length body - fence_len) fence_len)
              fence
      then String.trim (String.sub body 0 (String.length body - fence_len))
      else body
    | None -> s
  else s

let of_string (s : string) : (Fusion_types.judge_synthesis, string) result =
  let s = strip_fences s in
  match Yojson.Safe.from_string s with
  | json -> of_json json
  | exception Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
