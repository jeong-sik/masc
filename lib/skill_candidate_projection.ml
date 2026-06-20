(** Read-side draft skill candidates derived from MASC memory. *)

type promotion_state = Candidate

type skill_candidate =
  { id : string
  ; agent_name : string
  ; source_kind : string
  ; source_id : string
  ; source_ref : string
  ; pattern : string
  ; evidence_refs : string list
  ; success_count : int
  ; failure_count : int
  ; confidence : float
  ; applicable_tools : string list
  ; promotion_state : promotion_state
  ; risk_notes : string list
  }

let promotion_state_to_string = function Candidate -> "candidate"

let is_slug_char = function
  | 'a' .. 'z' | '0' .. '9' | '-' | '_' -> true
  | _ -> false
;;

let slugify raw =
  let raw = raw |> String.trim |> String.lowercase_ascii in
  let buf = Buffer.create (String.length raw) in
  String.iter
    (fun ch -> Buffer.add_char buf (if is_slug_char ch then ch else '-'))
    raw;
  let s = Buffer.contents buf in
  let len = String.length s in
  let rec left i =
    if i >= len then len else if Char.equal s.[i] '-' then left (i + 1) else i
  in
  let rec right i =
    if i < 0 then -1 else if Char.equal s.[i] '-' then right (i - 1) else i
  in
  let l = left 0 in
  let r = right (len - 1) in
  if l > r then "untitled" else String.sub s l (r - l + 1)
;;

let has_uri_scheme s =
  let len = String.length s in
  let rec loop i =
    if i + 2 >= len
    then false
    else if Char.equal s.[i] ':' && Char.equal s.[i + 1] '/' && Char.equal s.[i + 2] '/'
    then i > 0
    else loop (i + 1)
  in
  loop 0
;;

let dedup_preserve_order xs =
  let seen = Hashtbl.create 8 in
  List.filter
    (fun x ->
      if Hashtbl.mem seen x
      then false
      else (
        Hashtbl.add seen x ();
        true))
    xs
;;

let source_procedure_ref (p : Procedural_memory.procedure) =
  Printf.sprintf "procedure://%s/%s" (slugify p.agent_name) (slugify p.id)
;;

let source_memory_fact_ref ~agent_name (fact : Keeper_memory_os_types.fact) =
  Printf.sprintf "memory-os-fact://%s/%s/%s" (slugify agent_name)
    (slugify fact.source.trace_id)
    (slugify (Keeper_memory_os_types.normalize_claim fact.claim))
;;

let evidence_ref_of_procedure p evidence =
  let evidence = String.trim evidence in
  if String.equal evidence ""
  then None
  else if has_uri_scheme evidence
  then Some evidence
  else
    Some
      (Printf.sprintf "%s/evidence/%s" (source_procedure_ref p) (slugify evidence))
;;

let evidence_refs (p : Procedural_memory.procedure) =
  source_procedure_ref p
  :: (p.evidence |> List.filter_map (evidence_ref_of_procedure p))
  |> dedup_preserve_order
;;

let candidate_id ~source_kind ~source_id =
  match source_kind with
  | "procedure" -> Printf.sprintf "skill-candidate-%s" (slugify source_id)
  | _ -> Printf.sprintf "skill-candidate-%s-%s" (slugify source_kind) (slugify source_id)
;;

let procedure_risk_notes =
  [ "generated from procedural memory; requires human approval before installation"
  ; "verify evidence refs before promoting to an approved skill"
  ; "applicable tools require human curation before approval"
  ]
;;

let memory_fact_risk_notes =
  [ "generated from Memory OS fact; requires human approval before installation"
  ; "numeric outcome confidence is unavailable until linked evidence is curated"
  ; "validated_approach and lesson facts are advisory until evidence is reviewed"
  ; "do not inject into keeper prompts before approval"
  ]
;;

let candidate_of_procedure (p : Procedural_memory.procedure) =
  if not (Procedural_memory.is_crystallized p)
  then None
  else
    let source_kind = "procedure" in
    let source_id = p.id in
    let source_ref = source_procedure_ref p in
    Some
      { id = candidate_id ~source_kind ~source_id
      ; agent_name = p.agent_name
      ; source_kind
      ; source_id
      ; source_ref
      ; pattern = p.pattern
      ; evidence_refs = evidence_refs p
      ; success_count = p.success_count
      ; failure_count = p.failure_count
      ; confidence = p.confidence
      ; applicable_tools = []
      ; promotion_state = Candidate
      ; risk_notes = procedure_risk_notes
      }
;;

let is_memory_fact_skill_candidate (fact : Keeper_memory_os_types.fact) =
  match fact.category with
  | Keeper_memory_os_types.Validated_approach | Keeper_memory_os_types.Lesson -> true
  | Keeper_memory_os_types.Code_change
  | Keeper_memory_os_types.Fact
  | Keeper_memory_os_types.Preference
  | Keeper_memory_os_types.Blocker
  | Keeper_memory_os_types.Goal
  | Keeper_memory_os_types.Constraint
  | Keeper_memory_os_types.Ephemeral
  | Keeper_memory_os_types.Unknown _ -> false
;;

let memory_fact_source_id (fact : Keeper_memory_os_types.fact) =
  Printf.sprintf "%s-%s" fact.source.trace_id
    (Keeper_memory_os_types.normalize_claim fact.claim)
;;

let memory_fact_evidence_refs ~agent_name (fact : Keeper_memory_os_types.fact) =
  let trace_ref =
    Printf.sprintf "keeper-turn://%s/%d" (slugify fact.source.trace_id) fact.source.turn
  in
  let tool_ref =
    fact.source.tool_call_id
    |> Option.map (fun tool_call_id -> Printf.sprintf "tool-call://%s" (slugify tool_call_id))
  in
  [ Some (source_memory_fact_ref ~agent_name fact); Some trace_ref; tool_ref ]
  |> List.filter_map Fun.id
  |> dedup_preserve_order
;;

let candidate_of_memory_fact ~agent_name (fact : Keeper_memory_os_types.fact) =
  if not (is_memory_fact_skill_candidate fact)
  then None
  else
    let source_kind = "memory_os_fact" in
    let source_id = memory_fact_source_id fact in
    let source_ref = source_memory_fact_ref ~agent_name fact in
    Some
      { id = candidate_id ~source_kind ~source_id
      ; agent_name
      ; source_kind
      ; source_id
      ; source_ref
      ; pattern = fact.claim
      ; evidence_refs = memory_fact_evidence_refs ~agent_name fact
      ; success_count = 0
      ; failure_count = 0
      ; confidence = 0.0
      ; applicable_tools = []
      ; promotion_state = Candidate
      ; risk_notes = memory_fact_risk_notes
      }
;;

let candidates_of_procedures procedures =
  procedures
  |> List.filter_map candidate_of_procedure
  |> List.sort (fun a b -> Float.compare b.confidence a.confidence)
;;

let candidates_of_memory_facts ~agent_name facts =
  facts
  |> List.filter_map (candidate_of_memory_fact ~agent_name)
  |> List.sort (fun a b -> Float.compare b.confidence a.confidence)
;;

let top_candidates ~agent_name ~limit =
  Procedural_memory.top_procedures ~agent_name ~limit |> candidates_of_procedures
;;

let string_list_json xs = `List (List.map (fun s -> `String s) xs)

let to_json (c : skill_candidate) : Yojson.Safe.t =
  `Assoc
    [ "schema", `String "masc.skill_candidate_projection.v1"
    ; "id", `String c.id
    ; "agent_name", `String c.agent_name
    ; "source_kind", `String c.source_kind
    ; "source_id", `String c.source_id
    ; "source_ref", `String c.source_ref
    ; "pattern", `String c.pattern
    ; "evidence_refs", string_list_json c.evidence_refs
    ; "success_count", `Int c.success_count
    ; "failure_count", `Int c.failure_count
    ; "confidence", `Float c.confidence
    ; "applicable_tools", string_list_json c.applicable_tools
    ; "promotion_state", `String (promotion_state_to_string c.promotion_state)
    ; "risk_notes", string_list_json c.risk_notes
    ]
;;

let bullet_list = function
  | [] -> "- (none)"
  | xs -> xs |> List.map (Printf.sprintf "- %s") |> String.concat "\n"
;;

let render_skill_draft (c : skill_candidate) =
  Printf.sprintf
    {|---
name: %s
description: "Draft skill candidate generated from MASC memory; requires approval before use."
---

# %s

Status: %s
Agent: %s
Source: %s
Confidence: %.3f

## When To Use

%s

## Evidence

%s

## Applicable Tools

%s

## Guardrails

%s
|}
    (slugify c.id)
    c.id
    (promotion_state_to_string c.promotion_state)
    c.agent_name
    c.source_ref
    c.confidence
    c.pattern
    (bullet_list c.evidence_refs)
    (bullet_list c.applicable_tools)
    (bullet_list c.risk_notes)
;;
