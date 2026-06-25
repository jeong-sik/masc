type decision =
  | Pass
  | Reject of
      { reason : string
      ; rule_id : string
      ; hint : string
      ; payload_json : Yojson.Safe.t
      }

let rule_id_evidence_incomplete = "cdal_evidence_incomplete"

let hint_evidence_incomplete =
  "Supply task-completion evidence: notes >= 20 chars summarising what \
   changed AND every contract.required_evidence entry mentioned verbatim, \
   OR at least one handoff_context.evidence_refs reference (file path, PR \
   number, commit hash, trace id, or any reference URL). Pure-placeholder \
   notes ('done', 'ok', etc.) with no required_evidence mention and no \
   handoff evidence_refs keep this gate closed."

let reason_evidence_incomplete ~required_evidence =
  Printf.sprintf
    "Task-completion evidence is insufficient: %d required evidence \
     entry/entries unsatisfied and no substantive notes or handoff \
     reference supplied"
    (List.length required_evidence)

let starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.sub value 0 prefix_len = prefix

let is_hex_char = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

let is_commit_ref value =
  let len = String.length value in
  len >= 7 && len <= 40 && String.for_all is_hex_char value

let contains_path_separator value =
  String.contains value '/' || String.contains value '\\'

let is_file_ref_char = function
  | '0' .. '9'
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '/'
  | '\\'
  | '.'
  | '_'
  | '-'
  | '~'
  | '@'
  | ':' -> true
  | _ -> false

let is_extension_char = function
  | '0' .. '9' | 'a' .. 'z' | 'A' .. 'Z' -> true
  | _ -> false

let has_plausible_extension value =
  match String.rindex_opt value '.' with
  | None -> false
  | Some idx ->
    let len = String.length value in
    let ext_len = len - idx - 1 in
    idx > 0
    && ext_len >= 1
    && ext_len <= 12
    && String.for_all is_file_ref_char value
    && String.for_all is_extension_char (String.sub value (idx + 1) ext_len)

let looks_like_file_path value =
  String.for_all is_file_ref_char value
  && (contains_path_separator value || has_plausible_extension value)

let is_pr_ref value =
  let len = String.length value in
  (len > 3
   && (starts_with ~prefix:"PR#" value || starts_with ~prefix:"pr#" value)
   && String.for_all
        (function
          | '0' .. '9' -> true
          | _ -> false)
        (String.sub value 3 (len - 3)))
  || (len > 1
      && value.[0] = '#'
      && String.for_all
           (function
             | '0' .. '9' -> true
             | _ -> false)
           (String.sub value 1 (len - 1)))

let is_trace_ref value =
  starts_with ~prefix:"trace:" value
  || starts_with ~prefix:"turn:" value
  || starts_with ~prefix:"receipt:" value

let evidence_ref_is_concrete ref_ =
  let value = String.trim ref_ in
  if String.equal value "" then false
  else
    starts_with ~prefix:"http://" value
    || starts_with ~prefix:"https://" value
    || starts_with ~prefix:"file://" value
    || is_pr_ref value
    || is_commit_ref value
    || is_trace_ref value
    || looks_like_file_path value

let is_reference_token_char = function
  | '0' .. '9'
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '/'
  | '\\'
  | '_'
  | '-'
  | '~'
  | '@' -> true
  | _ -> false

let reference_boundary_match haystack needle start =
  let needle_len = String.length needle in
  let before =
    start = 0 || not (is_reference_token_char haystack.[start - 1])
  in
  let after_idx = start + needle_len in
  let after =
    after_idx >= String.length haystack
    || not (is_reference_token_char haystack.[after_idx])
  in
  before && after

let notes_mention_required_entry ~notes entry =
  let needle = String.lowercase_ascii entry in
  let haystack = String.lowercase_ascii notes in
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0 || needle_len > haystack_len then false
  else
    let limit = haystack_len - needle_len in
    let rec loop i =
      if i > limit then false
      else if
        String.sub haystack i needle_len = needle
        && reference_boundary_match haystack needle i
      then true
      else loop (i + 1)
    in
    loop 0

(* Heuristic: an "evidence entry" is satisfied when the notes or
   concrete handoff_context.evidence_refs mention a non-placeholder string that
   names it. Blank required entries are never evidence. *)
let evidence_entry_satisfied
    ~notes
    ~(handoff_context : Masc_domain.task_handoff_context option)
    (entry : string)
  =
  let entry_trimmed = String.trim entry in
  if String.equal entry_trimmed "" then false
  else
    let entry_lower = String.lowercase_ascii entry_trimmed in
    let in_notes = notes_mention_required_entry ~notes entry_lower in
    let in_handoff =
      match handoff_context with
      | None -> false
      | Some hc ->
        List.exists
          (fun ref_ ->
            let r = String.lowercase_ascii (String.trim ref_) in
            evidence_ref_is_concrete ref_ && r = entry_lower)
          hc.evidence_refs
    in
    in_notes || in_handoff

let unsatisfied_required_evidence
    ~notes
    ~handoff_context
    (contract : Masc_domain.task_contract option)
  =
  match contract with
  | None -> []
  | Some c ->
    List.filter
      (fun e -> not (evidence_entry_satisfied ~notes ~handoff_context e))
      c.required_evidence

let task_has_contract (task_opt : Masc_domain.task option) =
  match task_opt with
  | None -> false
  | Some t -> Option.is_some t.contract

(* Placeholder note bodies that {!evidence_is_substantive} treats as
   "keeper supplied nothing".  Compared on the trimmed lowercase form.
   This is deliberately conservative: the goal is to recognise clearly
   empty / null-equivalent done messages, not to second-guess substantive
   prose. *)
let placeholder_note_bodies =
  [ ""
  ; "done"
  ; "ok"
  ; "complete"
  ; "completed"
  ; "draft"
  ; "pending"
  ; "n/a"
  ; "na"
  ; "tbd"
  ; "todo"
  ]

let notes_are_substantive (notes : string) : bool =
  let trimmed = String.trim notes |> String.lowercase_ascii in
  if List.exists (String.equal trimmed) placeholder_note_bodies then false
  else String.length trimmed >= 20

let handoff_supplies_evidence
    (handoff_context : Masc_domain.task_handoff_context option) : bool =
  match handoff_context with
  | None -> false
  | Some hc ->
    List.exists
      evidence_ref_is_concrete
      hc.evidence_refs

(* Evidence-substantiveness gate for explicit verification submissions. Normal
   task completion is LLM-reviewed before it reaches [Done]; this gate only
   checks that a caller putting a task into AwaitingVerification supplied
   evidence a reviewer can inspect downstream. A contracted task passes when
   *every* required_evidence entry is mentioned in notes/handoff AND the caller
   supplied at least one of: substantive notes, or a handoff evidence reference
   (file path, PR number, commit hash, trace id, or any reference URL). Empty
   notes with empty required_evidence still rejects, since that carries no
   evidence at all. *)
let evidence_is_substantive
    ~notes
    ~(handoff_context : Masc_domain.task_handoff_context option)
    (contract : Masc_domain.task_contract option) : bool =
  match contract with
  | None -> false
  | Some c ->
    let required_evidence_satisfied =
      unsatisfied_required_evidence ~notes ~handoff_context (Some c) = []
    in
    let any_evidence_supplied =
      notes_are_substantive notes || handoff_supplies_evidence handoff_context
    in
    required_evidence_satisfied && any_evidence_supplied

let evidence_summary_payload
    ~(notes : string)
    ~(handoff_context : Masc_domain.task_handoff_context option) : Yojson.Safe.t =
  `Assoc
    [ "notes_length", `Int (String.length (String.trim notes))
    ; ( "handoff_evidence_refs_count"
      , `Int
          (match handoff_context with
           | None -> 0
           | Some hc -> List.length hc.evidence_refs) )
    ]

let decide ~task_id ~task_opt ~notes ~handoff_context () =
  match (task_opt : Masc_domain.task option) with
  | Some t when Option.is_some t.contract ->
    if evidence_is_substantive ~notes ~handoff_context t.contract
    then begin
      Log.Task.info "cdal_evidence_gate PASS task=%s notes_len=%d handoff_refs=%d"
        task_id (String.length (String.trim notes))
        (match handoff_context with None -> 0 | Some hc -> List.length hc.evidence_refs);
      Pass
    end
    else
      let unsatisfied =
        unsatisfied_required_evidence ~notes ~handoff_context t.contract
      in
      Log.Task.warn "cdal_evidence_gate REJECT task=%s unsatisfied=%d notes_len=%d handoff_refs=%d rule=%s"
        task_id (List.length unsatisfied) (String.length (String.trim notes))
        (match handoff_context with None -> 0 | Some hc -> List.length hc.evidence_refs)
        rule_id_evidence_incomplete;
      Reject
        { reason = reason_evidence_incomplete ~required_evidence:unsatisfied
        ; rule_id = rule_id_evidence_incomplete
        ; hint = hint_evidence_incomplete
        ; payload_json =
            `Assoc
              [ "task_id", `String task_id
              ; "contract_required", `Bool true
              ; ( "required_evidence_unsatisfied"
                , Json_util.json_string_list unsatisfied )
              ; ( "evidence_summary"
                , evidence_summary_payload ~notes ~handoff_context )
              ]
        }
  | _ ->
    (* Analysis-only task bypass: a task with no contract has nothing to
       verify, so the gate must not block keeper_task_done. *)
    Pass
