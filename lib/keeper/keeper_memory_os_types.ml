(** Keeper_memory_os_types — typed schema for the tiered Memory OS.

    Facts are immutable claims extracted by the librarian. Episodes group
    related facts with a short summary and metadata. *)

(* Canonical JSON wire keys for Memory OS persistence and librarian ingestion.
   The schema module owns these strings so the parser, retry prompt, persistence
   codec, and tests cannot drift by maintaining parallel literal sets. *)
let wire_field_trace_id = "trace_id"
let wire_field_turn = "turn"
let wire_field_tool_call_id = "tool_call_id"
let wire_field_claim = "claim"
let wire_field_category = "category"
let wire_field_source = "source"
let wire_field_first_seen = "first_seen"
let wire_field_last_verified_at = "last_verified_at"
let wire_field_claim_id = "claim_id"
let wire_field_generation = "generation"
let wire_field_episode_summary = "episode_summary"
let wire_field_claims = "claims"
let wire_field_source_turn = "source_turn"
let wire_field_source_tool_call_id = "source_tool_call_id"
let wire_field_source_turn_range = "source_turn_range"
let wire_field_lo = "lo"
let wire_field_hi = "hi"
let wire_field_created_at = "created_at"
let wire_field_terminal_marker = "terminal_marker"

module Wire_field_set = Set.Make (String)

let wire_field_set fields =
  List.fold_left (fun set field -> Wire_field_set.add field set) Wire_field_set.empty fields
;;

let closed_fields allowed fields =
  let rec loop seen = function
    | [] -> true
    | (field, _) :: rest ->
      if
        Wire_field_set.mem field seen
        || not (Wire_field_set.mem field allowed)
      then false
      else loop (Wire_field_set.add field seen) rest
  in
  loop Wire_field_set.empty fields
;;

let provenance_wire_fields =
  wire_field_set [ wire_field_trace_id; wire_field_turn; wire_field_tool_call_id ]
;;

let fact_wire_fields =
  wire_field_set
    [ wire_field_claim
    ; wire_field_category
    ; wire_field_source
    ; wire_field_first_seen
    ; wire_field_last_verified_at
    ; wire_field_claim_id
    ]
;;

let source_turn_range_wire_fields = wire_field_set [ wire_field_lo; wire_field_hi ]

let episode_wire_fields =
  wire_field_set
    [ wire_field_trace_id
    ; wire_field_generation
    ; wire_field_episode_summary
    ; wire_field_claims
    ; wire_field_source_turn_range
    ; wire_field_created_at
    ; wire_field_terminal_marker
    ]
;;

let wire_librarian_episode_fields = [ wire_field_episode_summary; wire_field_claims ]

let wire_librarian_claim_fields =
  [ wire_field_claim
  ; wire_field_category
  ; wire_field_source_turn
  ; wire_field_source_tool_call_id
  ; wire_field_claim_id
  ]
;;

type provenance_event =
  { trace_id : string
  ; turn : int
  ; tool_call_id : string option
  }

(* The librarian taxonomy as a closed sum. The LLM emits one exact category
   token; anything outside this vocabulary is rejected. Categories are model
   context only: no variant grants retention, expiry, or promotion authority. *)
type category =
  | Code_change
  | Fact
  | Preference
  | Blocker
  | Goal
  | Constraint
  | Validated_approach
  | Lesson

let category_to_string = function
  | Code_change -> "code_change"
  | Fact -> "fact"
  | Preference -> "preference"
  | Blocker -> "blocker"
  | Goal -> "goal"
  | Constraint -> "constraint"
  | Validated_approach -> "validated_approach"
  | Lesson -> "lesson"
;;

let all_categories =
  [ Fact
  ; Preference
  ; Blocker
  ; Goal
  ; Constraint
  ; Validated_approach
  ; Lesson
  ; Code_change
  ]
;;

let category_of_string s =
  match s with
  | "code_change" -> Some Code_change
  | "fact" -> Some Fact
  | "preference" -> Some Preference
  | "blocker" -> Some Blocker
  | "goal" -> Some Goal
  | "constraint" -> Some Constraint
  | "validated_approach" -> Some Validated_approach
  | "lesson" -> Some Lesson
  | _ -> None
;;

(* The fact carries only the claim, model-produced context, provenance, and
   producer timestamps. A fact's value is the librarian's judgment, not a score
   computed from those fields. *)
type fact =
  { claim : string
  ; category : category
  ; source : provenance_event
  ; first_seen : float
  ; last_verified_at : float option
  ; claim_id : string option
    (* Optional producer-emitted stable conclusion id. It is preserved exactly;
       absent ids use exact observation identity, never normalized prose. *)
  }

(* Presentation timestamp used by recall and dashboard ordering. It is not a
   retention boundary or a truth verdict. *)
let reference_time (f : fact) =
  match f.last_verified_at with
  | Some t -> t
  | None -> f.first_seen
;;

let source_turn_range_of_facts = function
  | [] -> None
  | first :: rest ->
    let initial = first.source.turn in
    let lo =
      List.fold_left
        (fun current fact -> min current fact.source.turn)
        initial
        rest
    in
    let hi =
      List.fold_left
        (fun current fact -> max current fact.source.turn)
        initial
        rest
    in
    Some (lo, hi)
;;

type episode =
  { trace_id : string
  ; generation : int
  ; episode_summary : string
  ; claims : fact list
  ; source_turn_range : (int * int) option
  ; created_at : float
  ; terminal_marker : string option
  }

(* ---------- JSON codecs ---------- *)

let json_string_field key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`String s) -> Some s
  | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null)
  | None -> None
;;

let json_int_field key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`Int i) -> Some i
  | Some (`Assoc _ | `Bool _ | `Float _ | `Intlit _ | `List _ | `Null | `String _)
  | None -> None
;;

let json_float_field key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | Some (`Assoc _ | `Bool _ | `Intlit _ | `List _ | `Null | `String _) | None -> None
;;

let json_bool_field key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`Bool b) -> Some b
  | Some (`Assoc _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _)
  | None -> None
;;

let non_empty_string value = not (String.equal (String.trim value) "")

let optional_non_empty_string = function
  | None -> true
  | Some value -> non_empty_string value
;;

let optional_finite_float = function
  | None -> true
  | Some value -> Float.is_finite value
;;

let provenance_event_is_valid (event : provenance_event) =
  non_empty_string event.trace_id
  && event.turn >= 0
  && optional_non_empty_string event.tool_call_id
;;

let provenance_event_to_json (e : provenance_event) =
  if not (provenance_event_is_valid e)
  then invalid_arg "memory provenance event is invalid";
  let base =
    [ wire_field_trace_id, `String e.trace_id
    ; wire_field_turn, `Int e.turn
    ]
  in
  let tool =
    match e.tool_call_id with
    | Some id -> [ wire_field_tool_call_id, `String id ]
    | None -> []
  in
  `Assoc (base @ tool)
;;

let provenance_event_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields when closed_fields provenance_wire_fields fields ->
    (match
       ( json_string_field wire_field_trace_id fields
       , json_int_field wire_field_turn fields
       , (match List.assoc_opt wire_field_tool_call_id fields with
          | None -> Some None
          | Some (`String value) -> Some (Some value)
          | Some _ -> None) )
     with
     | Some trace_id, Some turn, Some tool_call_id ->
       let event = { trace_id; turn; tool_call_id } in
       if provenance_event_is_valid event then Some event else None
     | _ -> None)
  | `Assoc _
  | `Bool _
  | `Float _
  | `Int _
  | `Intlit _
  | `List _
  | `Null
  | `String _ -> None
;;

let claim_id_is_valid id = not (String.equal (String.trim id) "")

(* Producer identity is authoritative and preserved byte-for-byte. If the model
   omits it, the fallback is the exact source event plus exact claim payload: it
   prevents accidental merging across observations without classifying or
   normalizing claim prose. *)
let claim_identity (f : fact) =
  match f.claim_id with
  | Some id when claim_id_is_valid id -> "id:" ^ id
  | Some _ | None ->
    (* [source.turn] is deliberately excluded: the librarian's turn numbers
       are indices into the sliding prompt window ([List.mapi] in
       [Keeper_librarian.format_messages_for_prompt]), so the same event
       re-extracted after the window moves carries a different number.
       Including it made write-time dedupe structurally impossible — every
       re-extraction minted a fresh identity. The stable observation
       coordinates are the trace, the producing tool call (when any), and
       the exact claim bytes; [turn] stays on the fact as display
       provenance only. *)
    "observation:"
    ^ Yojson.Safe.to_string
        (`Assoc
           ([ wire_field_trace_id, `String f.source.trace_id ]
            @ (match f.source.tool_call_id with
               | Some tool_call_id ->
                 [ wire_field_source_tool_call_id, `String tool_call_id ]
               | None -> [])
            @ [ wire_field_claim, `String f.claim ]))
;;

let optional_float_field key = function
  | Some value -> [ key, `Float value ]
  | None -> []
;;

let fact_to_json (f : fact) =
  if not (non_empty_string f.claim)
  then invalid_arg "memory fact claim must be non-empty";
  if not (provenance_event_is_valid f.source)
  then invalid_arg "memory fact provenance is invalid";
  if not (Float.is_finite f.first_seen)
  then invalid_arg "memory fact first_seen must be finite";
  if not (optional_finite_float f.last_verified_at)
  then invalid_arg "memory fact last_verified_at must be finite";
  let fields =
    [ wire_field_claim, `String f.claim
    ; wire_field_category, `String (category_to_string f.category)
    ; wire_field_source, provenance_event_to_json f.source
    ; wire_field_first_seen, `Float f.first_seen
    ]
    @ optional_float_field wire_field_last_verified_at f.last_verified_at
    @ (match f.claim_id with
       | Some id when claim_id_is_valid id -> [ wire_field_claim_id, `String id ]
       | Some _ -> invalid_arg "memory fact claim_id must be non-empty"
       | None -> [])
  in
  `Assoc fields
;;

let optional_float_json_field key fields =
  match List.assoc_opt key fields with
  | None -> Some None
  | Some (`Float value) -> Some (Some value)
  | Some (`Int value) -> Some (Some (float_of_int value))
  | Some _ -> None
;;

(* Strict decoder for the closed canonical fact shape. *)
let fact_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields when closed_fields fact_wire_fields fields ->
    (match
       ( json_string_field wire_field_claim fields
       , json_string_field wire_field_category fields
       , List.assoc_opt wire_field_source fields
       , json_float_field wire_field_first_seen fields
       , (match List.assoc_opt wire_field_claim_id fields with
          | None -> Some None
          | Some (`String id) when claim_id_is_valid id -> Some (Some id)
          | Some _ -> None)
       , optional_float_json_field wire_field_last_verified_at fields )
     with
     | ( Some claim
       , Some category_str
       , Some source_json
       , Some first_seen
       , Some claim_id
       , Some last_verified_at ) ->
       (match provenance_event_of_json source_json with
        | Some source ->
          (match category_of_string category_str with
           | None -> None
           | Some category
             when non_empty_string claim
                  && Float.is_finite first_seen
                  && optional_finite_float last_verified_at ->
             Some
               { claim
               ; category
               ; source
               ; first_seen
               ; last_verified_at
               ; claim_id
               }
           | Some _ -> None)
        | None -> None)
     | _ -> None)
  | `Assoc _
  | `Bool _
  | `Float _
  | `Int _
  | `Intlit _
  | `List _
  | `Null
  | `String _ -> None
;;

let episode_to_json (e : episode) =
  if not (non_empty_string e.trace_id)
  then invalid_arg "memory episode trace_id must be non-empty";
  if e.generation < 0
  then invalid_arg "memory episode generation must be non-negative";
  if not (non_empty_string e.episode_summary)
  then invalid_arg "memory episode summary must be non-empty";
  if not (Float.is_finite e.created_at)
  then invalid_arg "memory episode created_at must be finite";
  if not (optional_non_empty_string e.terminal_marker)
  then invalid_arg "memory episode terminal_marker must be non-empty";
  if
    not
      (List.for_all
         (fun fact -> String.equal fact.source.trace_id e.trace_id)
         e.claims)
  then invalid_arg "memory episode claim trace_id does not match the episode";
  if e.source_turn_range <> source_turn_range_of_facts e.claims
  then invalid_arg "memory episode source_turn_range does not match its claims";
  let range_json =
    match e.source_turn_range with
    | Some (lo, hi) when lo >= 0 && hi >= lo ->
      [ wire_field_source_turn_range
      , `Assoc [ wire_field_lo, `Int lo; wire_field_hi, `Int hi ]
      ]
    | Some _ -> invalid_arg "memory episode source_turn_range is invalid"
    | None -> []
  in
  `Assoc
    ([ wire_field_trace_id, `String e.trace_id
     ; wire_field_generation, `Int e.generation
     ; wire_field_episode_summary, `String e.episode_summary
     ; ( wire_field_claims
       , `List (List.rev (List.rev_map fact_to_json e.claims)) )
     ; wire_field_created_at, `Float e.created_at
     ]
    @ range_json
    @ (match e.terminal_marker with
        | Some marker -> [ wire_field_terminal_marker, `String marker ]
        | None -> []))
;;

let facts_of_json values =
  let rec loop facts = function
    | [] -> Some (List.rev facts)
    | json :: rest ->
      (match fact_of_json json with
       | Some fact -> loop (fact :: facts) rest
       | None -> None)
  in
  loop [] values
;;

let optional_string_json_field key fields =
  match List.assoc_opt key fields with
  | None -> Some None
  | Some (`String value) -> Some (Some value)
  | Some _ -> None
;;

let source_turn_range_field fields =
  match List.assoc_opt wire_field_source_turn_range fields with
  | None -> Some None
  | Some (`Assoc range_fields)
    when closed_fields source_turn_range_wire_fields range_fields ->
    (match json_int_field wire_field_lo range_fields, json_int_field wire_field_hi range_fields with
     | Some lo, Some hi when lo >= 0 && hi >= lo -> Some (Some (lo, hi))
     | Some _, Some _ -> None
     | (Some _, None) | (None, Some _) | (None, None) -> None)
  | Some _ -> None
;;

let episode_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields when closed_fields episode_wire_fields fields ->
    (match
       ( json_string_field wire_field_trace_id fields
       , json_int_field wire_field_generation fields
       , json_string_field wire_field_episode_summary fields
       , (match List.assoc_opt wire_field_claims fields with
          | Some (`List claim_items) -> facts_of_json claim_items
          | Some _ | None -> None)
       , source_turn_range_field fields
       , json_float_field wire_field_created_at fields
       , optional_string_json_field wire_field_terminal_marker fields )
     with
     | ( Some trace_id
       , Some generation
       , Some episode_summary
       , Some claims
       , Some source_turn_range
       , Some created_at
       , Some terminal_marker ) ->
       if
         non_empty_string trace_id
         && generation >= 0
         && non_empty_string episode_summary
         && Float.is_finite created_at
         && optional_non_empty_string terminal_marker
         && List.for_all
              (fun fact -> String.equal fact.source.trace_id trace_id)
              claims
         && source_turn_range = source_turn_range_of_facts claims
       then
         Some
           { trace_id
           ; generation
           ; episode_summary
           ; claims
           ; source_turn_range
           ; created_at
           ; terminal_marker
           }
       else None
     | _ -> None)
  | `Assoc _
  | `Bool _
  | `Float _
  | `Int _
  | `Intlit _
  | `List _
  | `Null
  | `String _ -> None
;;
