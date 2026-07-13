(** Keeper_memory_os_types — typed schema for the tiered Memory OS.

    Facts are immutable, versioned claims extracted by the librarian.
    Episodes group related facts with a short summary and metadata. *)

(* Kept at the current on-disk schema label. Product-specific reference fields
   are not part of the generic Memory fact type. *)
let schema_version = "rfc0259-v1"

(* RFC-0244 Tier 2: the shared semantic store reuses the per-keeper IO/codec
   under a reserved id. A leading underscore is not produced by keeper naming, so
   no real keeper collides with its file (keepers/_shared.facts.jsonl); the
   consolidator additionally filters this id out of its source keeper list. *)
let shared_store_id = "_shared"

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
let wire_field_valid_until = "valid_until"
let wire_field_last_verified_at = "last_verified_at"
let wire_field_observed_by = "observed_by"
let wire_field_claim_id = "claim_id"
let wire_field_claim_kind = "claim_kind"
let wire_field_schema_version = "schema_version"
let wire_field_generation = "generation"
let wire_field_episode_summary = "episode_summary"
let wire_field_claims = "claims"
let wire_field_open_items = "open_items"
let wire_field_constraints = "constraints"
let wire_field_preserved_tool_refs = "preserved_tool_refs"
let wire_field_source_turn = "source_turn"
let wire_field_source_tool_call_id = "source_tool_call_id"
let wire_field_source_turn_range = "source_turn_range"
let wire_field_lo = "lo"
let wire_field_hi = "hi"
let wire_field_created_at = "created_at"
let wire_field_terminal_marker = "terminal_marker"

let wire_librarian_episode_fields =
  [ wire_field_episode_summary
  ; wire_field_claims
  ; wire_field_open_items
  ; wire_field_constraints
  ; wire_field_preserved_tool_refs
  ]
;;

let wire_librarian_claim_fields =
  [ wire_field_claim
  ; wire_field_category
  ; wire_field_source_turn
  ; wire_field_source_tool_call_id
  ; wire_field_claim_id
  ; wire_field_claim_kind
  ]
;;

type provenance_event =
  { trace_id : string
  ; turn : int
  ; tool_call_id : string option
  }

(* The librarian taxonomy as a closed sum. The LLM emits a category label;
   [category_of_string] parses it once at the producer boundary, with [Unknown]
   preserving any label outside the current vocabulary. Categories are model
   context only: no variant grants retention, expiry, or promotion authority. *)
type category =
  | Code_change
  | Fact
  | Preference
  | Blocker
  | Goal
  | Constraint
  | Ephemeral
  | Validated_approach
  | Lesson
  | Unknown of string

let category_to_string = function
  | Code_change -> "code_change"
  | Fact -> "fact"
  | Preference -> "preference"
  | Blocker -> "blocker"
  | Goal -> "goal"
  | Constraint -> "constraint"
  | Ephemeral -> "ephemeral"
  | Validated_approach -> "validated_approach"
  | Lesson -> "lesson"
  | Unknown s -> s
;;

let all_categories =
  [ Fact
  ; Preference
  ; Blocker
  ; Goal
  ; Constraint
  ; Ephemeral
  ; Validated_approach
  ; Lesson
  ; Code_change
  ]
;;

let category_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "code_change" -> Code_change
  | "fact" -> Fact
  | "preference" -> Preference
  | "blocker" -> Blocker
  | "goal" -> Goal
  | "constraint" -> Constraint
  | "ephemeral" -> Ephemeral
  | "validated_approach" -> Validated_approach
  | "lesson" -> Lesson
  | _ -> Unknown s
;;

(* Producer-emitted origin tag, orthogonal to [category]. It is parsed once at
   the librarian boundary and preserved as model context; it does not create a
   validity horizon or promotion hierarchy. *)
type claim_kind =
  | Self_observation (* transient first-person agent state: idle, looping, tool-timeout *)
  | External_state (* about the world/PR/issue; verifiable elsewhere *)
  | Durable_knowledge (* timeless rule / lesson independent of transient state *)
  | Diagnostic (* system-authored diagnostic artifact; not prompt-recallable knowledge *)

let claim_kind_to_string = function
  | Self_observation -> "self_observation"
  | External_state -> "external_state"
  | Durable_knowledge -> "durable_knowledge"
  | Diagnostic -> "diagnostic"
;;

let all_claim_kinds =
  [ Self_observation; External_state; Durable_knowledge; Diagnostic ]
;;

let librarian_claim_kinds =
  [ Self_observation; External_state; Durable_knowledge ]
;;

let claim_kind_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "self_observation" -> Some Self_observation
  | "external_state" -> Some External_state
  | "durable_knowledge" -> Some Durable_knowledge
  | "diagnostic" -> Some Diagnostic
  | _ -> None
;;

type persisted_claim_kind =
  | Persisted_claim_kind_absent
  | Persisted_claim_kind_valid of claim_kind
  | Persisted_claim_kind_invalid

let persisted_claim_kind_of_json fields =
  match List.assoc_opt wire_field_claim_kind fields with
  | None -> Persisted_claim_kind_absent
  | Some (`String raw) ->
    (match claim_kind_of_string raw with
     | Some claim_kind -> Persisted_claim_kind_valid claim_kind
     | None -> Persisted_claim_kind_invalid)
  | Some _ -> Persisted_claim_kind_invalid
;;

let category_and_claim_kind_of_persisted_row ~category_str ~claim_kind =
  match claim_kind with
  | Persisted_claim_kind_absent -> Some (category_of_string category_str, None)
  | Persisted_claim_kind_valid claim_kind ->
    Some (category_of_string category_str, Some claim_kind)
  | Persisted_claim_kind_invalid -> None
;;

(* The fact carries only the claim, model-produced context, provenance, the
   distinct-keeper corroboration set, and producer timestamps. A fact's value is
   the librarian's judgment, not a score computed from those fields. *)
type fact =
  { claim : string
  ; category : category
  ; claim_kind : claim_kind option
    (* Producer-emitted origin tag, orthogonal to [category]. It is model
       context only. *)
  ; source : provenance_event
  ; observed_by : string list
    (* RFC-0244 Tier 2 (shared semantic store) ONLY: the sorted set of distinct
       keeper ids that have corroborated this claim. Empty for Tier-1 per-keeper
       facts — a single keeper's store has no distinct keeper-source to track, so
       it is omitted from their JSON. *)
  ; first_seen : float
  ; valid_until : float option
  ; last_verified_at : float option
  ; schema_version : string
  ; claim_id : string option
    (* Optional producer-emitted stable conclusion id. It is preserved exactly;
       absent ids use exact observation identity, never normalized prose. *)
  }

let fact_effective_valid_until (fact : fact) = fact.valid_until

let fact_is_current ~now (fact : fact) =
  match fact_effective_valid_until fact with
  | None -> true
  | Some ts -> ts >= now
;;

(* Split facts only on the exact stored [valid_until] boundary. No category,
   claim-kind, or timestamp-derived fallback participates. *)
let partition_expired ~now (facts : fact list) =
  List.partition (fact_is_current ~now) facts
;;

(* Presentation timestamp used by recall and dashboard ordering. It is not an
   expiry boundary or a truth verdict; only [valid_until] has that authority. *)
let reference_time (f : fact) =
  match f.last_verified_at with
  | Some t -> t
  | None -> f.first_seen
;;

type episode =
  { trace_id : string
  ; generation : int
  ; episode_summary : string
  ; claims : fact list
  ; open_items : string list
  ; constraints : string list
  ; preserved_tool_refs : string list
  ; source_turn_range : (int * int) option
  ; created_at : float
  ; valid_until : float option
  ; terminal_marker : string option
  ; schema_version : string
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

let json_string_list_field key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`List items) ->
    let strings =
      List.filter_map
        (function
          | `String s -> Some s
          | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null -> None)
        items
    in
    if List.length strings = List.length items then Some strings else None
  | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _)
  | None -> None
;;

let provenance_event_to_json (e : provenance_event) =
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
  | `Assoc fields ->
    (match
       ( json_string_field wire_field_trace_id fields
       , json_int_field wire_field_turn fields
       , (match List.assoc_opt wire_field_tool_call_id fields with
          | None -> Some None
          | Some (`String value) -> Some (Some value)
          | Some _ -> None) )
     with
     | Some trace_id, Some turn, Some tool_call_id -> Some { trace_id; turn; tool_call_id }
     | _ -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
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
    "observation:"
    ^ Yojson.Safe.to_string
        (`Assoc
           [ wire_field_source, provenance_event_to_json f.source
           ; wire_field_claim, `String f.claim
           ])
;;

let optional_float_field key = function
  | Some value -> [ key, `Float value ]
  | None -> []
;;

let fact_to_json (f : fact) =
  if not (String.equal f.schema_version schema_version)
  then invalid_arg "memory fact schema_version is unsupported";
  let fields =
    [ wire_field_claim, `String f.claim
    ; wire_field_category, `String (category_to_string f.category)
    ; wire_field_source, provenance_event_to_json f.source
    ; wire_field_first_seen, `Float f.first_seen

    ; wire_field_schema_version, `String f.schema_version
    ]
    @ optional_float_field wire_field_valid_until f.valid_until
    @ optional_float_field wire_field_last_verified_at f.last_verified_at
    (* Tier-1 facts carry [], which is omitted so per-keeper stores stay
       byte-identical to pre-RFC-0244; only Tier-2 shared facts emit it. *)
    @ (match f.observed_by with
       | [] -> []
       | keepers ->
         [ wire_field_observed_by, `List (List.map (fun k -> `String k) keepers) ])
    @ (match f.claim_id with
       | Some id when claim_id_is_valid id -> [ wire_field_claim_id, `String id ]
       | Some _ -> invalid_arg "memory fact claim_id must be non-empty"
       | None -> [])
    (* RFC-0285 §3.1: the producer-emitted origin tag. Omitted when [None] so legacy
       rows stay byte-identical, appended LAST to keep the prior key order stable for
       the snapshot fingerprint. *)
    @ (match f.claim_kind with
       | Some k -> [ wire_field_claim_kind, `String (claim_kind_to_string k) ]
       | None -> [])
  in
  `Assoc fields
;;

(* Strict decoder for the canonical fact shape. Unknown JSON keys are inert, but
   every required Memory field must be present and well-typed. *)
let fact_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match
       ( json_string_field wire_field_claim fields
       , json_string_field wire_field_category fields
       , List.assoc_opt wire_field_source fields
       , json_float_field wire_field_first_seen fields
       , json_string_field wire_field_schema_version fields
       , (match List.assoc_opt wire_field_claim_id fields with
          | None -> Some None
          | Some (`String id) when claim_id_is_valid id -> Some (Some id)
          | Some _ -> None) )
     with
     | ( Some claim
       , Some category_str
       , Some source_json
       , Some first_seen
       , Some row_version
       , Some claim_id )
       when String.equal row_version schema_version ->
       (match provenance_event_of_json source_json with
        | Some source ->
          let last_verified_at = json_float_field wire_field_last_verified_at fields in
          let valid_until = json_float_field wire_field_valid_until fields in
          (* [observed_by] is optional for private facts. *)
          let observed_by =
            Option.value (json_string_list_field wire_field_observed_by fields) ~default:[]
          in
          let claim_kind = persisted_claim_kind_of_json fields in
          (match category_and_claim_kind_of_persisted_row ~category_str ~claim_kind with
           | None -> None
           | Some (category, claim_kind) ->
             Some
               { claim
               ; (* Parse once at the read boundary. Unknown categories remain
                    [Unknown raw], and invalid structured tags are rejected. *)
                 category
               ; claim_kind
               ; source
               ; observed_by
               ; first_seen
               ; valid_until
               ; last_verified_at
               ; schema_version = row_version
               ; claim_id
               })
        | None -> None)
     | (Some _, Some _, None, _, _, _)
     | (Some _, None, _, _, _, _)
     | (None, _, _, _, _, _)
     | (_, _, _, None, _, _)
     | (_, _, _, _, Some _, _)
     | (_, _, _, _, None, _) -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let episode_to_json (e : episode) =
  if not (String.equal e.schema_version schema_version)
  then invalid_arg "memory episode schema_version is unsupported";
  let range_json =
    match e.source_turn_range with
    | Some (lo, hi) ->
      [ wire_field_source_turn_range
      , `Assoc [ wire_field_lo, `Int lo; wire_field_hi, `Int hi ]
      ]
    | None -> []
  in
  `Assoc
    ([ wire_field_trace_id, `String e.trace_id
     ; wire_field_generation, `Int e.generation
     ; wire_field_episode_summary, `String e.episode_summary
     ; wire_field_claims, `List (List.map fact_to_json e.claims)
     ; wire_field_open_items, `List (List.map (fun s -> `String s) e.open_items)
     ; wire_field_constraints, `List (List.map (fun s -> `String s) e.constraints)
     ; ( wire_field_preserved_tool_refs
       , `List (List.map (fun s -> `String s) e.preserved_tool_refs) )
     ; wire_field_created_at, `Float e.created_at
     ; wire_field_schema_version, `String e.schema_version
     ]
     @ range_json
     @ optional_float_field wire_field_valid_until e.valid_until
     @ (match e.terminal_marker with
        | Some marker -> [ wire_field_terminal_marker, `String marker ]
        | None -> []))
;;

let rec facts_of_json = function
  | [] -> Some []
  | json :: rest ->
    (match fact_of_json json, facts_of_json rest with
     | Some fact, Some facts -> Some (fact :: facts)
     | None, _ | _, None -> None)
;;

let optional_float_json_field key fields =
  match List.assoc_opt key fields with
  | None -> Some None
  | Some (`Float value) -> Some (Some value)
  | Some (`Int value) -> Some (Some (float_of_int value))
  | Some _ -> None
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
  | Some (`Assoc range_fields) ->
    (match json_int_field wire_field_lo range_fields, json_int_field wire_field_hi range_fields with
     | Some lo, Some hi -> Some (Some (lo, hi))
     | (Some _, None) | (None, Some _) | (None, None) -> None)
  | Some _ -> None
;;

let episode_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match
       ( json_string_field wire_field_trace_id fields
       , json_int_field wire_field_generation fields
       , json_string_field wire_field_episode_summary fields
       , (match List.assoc_opt wire_field_claims fields with
          | Some (`List claim_items) -> facts_of_json claim_items
          | Some _ | None -> None)
       , json_string_list_field wire_field_open_items fields
       , json_string_list_field wire_field_constraints fields
       , json_string_list_field wire_field_preserved_tool_refs fields
       , source_turn_range_field fields
       , json_float_field wire_field_created_at fields
       , optional_float_json_field wire_field_valid_until fields
       , optional_string_json_field wire_field_terminal_marker fields
       , json_string_field wire_field_schema_version fields )
     with
     | ( Some trace_id
       , Some generation
       , Some episode_summary
       , Some claims
       , Some open_items
       , Some constraints
       , Some preserved_tool_refs
       , Some source_turn_range
       , Some created_at
       , Some valid_until
       , Some terminal_marker
       , Some row_version )
       when String.equal row_version schema_version ->
       Some
         { trace_id
         ; generation
         ; episode_summary
         ; claims
         ; open_items
         ; constraints
         ; preserved_tool_refs
         ; source_turn_range
         ; created_at
         ; valid_until
         ; terminal_marker
         ; schema_version = row_version
         }
     | _ -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;
