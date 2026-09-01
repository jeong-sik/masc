(** Keeper_memory_os_types — current Memory OS fact schema. *)

(* Canonical JSON wire keys for Memory OS persistence and librarian ingestion.
   The schema module owns these strings so the parser, retry prompt, persistence
   codec, and tests cannot drift by maintaining parallel literal sets. *)
let wire_field_claim = "claim"
let wire_field_category = "category"
let wire_field_first_seen = "first_seen"
let wire_field_last_seen = "last_seen"
let wire_field_reinforcement = "reinforcement"
let wire_field_origin = "origin"
let wire_field_memory_id = "memory_id"
let wire_field_reason = "reason"
let wire_field_basis = "basis"
let wire_field_kind = "kind"
let wire_field_derivations = "derivations"
let wire_field_rule_id = "rule_id"
let wire_field_premise_ids = "premise_ids"
let wire_field_trace_id = "trace_id"

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

let exact_fields allowed fields =
  closed_fields allowed fields
  && List.length fields = Wire_field_set.cardinal allowed
;;

let memory_id_prefix = "sha256:"

let is_lowercase_hex = function
  | '0' .. '9' | 'a' .. 'f' -> true
  | _ -> false
;;

let is_memory_id value =
  let prefix_length = String.length memory_id_prefix in
  String.length value = prefix_length + 64
  && String.starts_with ~prefix:memory_id_prefix value
  && String.for_all is_lowercase_hex (String.sub value prefix_length 64)
;;

let non_empty_string value = not (String.equal (String.trim value) "")

(* The canonical persisted fact shape is closed and field-exact. *)
let fact_wire_fields =
  wire_field_set
    [ wire_field_claim
    ; wire_field_category
    ; wire_field_first_seen
    ; wire_field_last_seen
    ; wire_field_reinforcement
    ; wire_field_origin
    ; wire_field_basis
    ]
;;

let wire_librarian_claim_fields =
  [ wire_field_claim; wire_field_category ]
;;

let wire_librarian_dropped_fields =
  [ wire_field_memory_id; wire_field_reason ]
;;

type dropped_statement =
  { memory_id : string
  ; reason : string
  }

let dropped_statement_to_json (d : dropped_statement) =
  if not (is_memory_id d.memory_id) || not (non_empty_string d.reason)
  then invalid_arg "dropped statement must name a memory identity and non-empty reason";
  `Assoc
    [ wire_field_memory_id, `String d.memory_id
    ; wire_field_reason, `String d.reason
    ]
;;

(* The inverse of [dropped_statement_to_json], kept beside it so the pair
   cannot drift. Field-exact: a statement carrying anything beyond
   memory_id/reason is a shape this build does not know and is rejected
   rather than read past. *)
let dropped_statement_of_json = function
  | `Assoc fields
    when closed_fields (wire_field_set wire_librarian_dropped_fields) fields
         && List.length fields = List.length wire_librarian_dropped_fields ->
    (match
       List.assoc_opt wire_field_memory_id fields
       , List.assoc_opt wire_field_reason fields
     with
     | Some (`String memory_id), Some (`String reason)
       when is_memory_id memory_id && non_empty_string reason ->
       Some { memory_id; reason }
     | _ -> None)
  | _ -> None
;;

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

(* Row-level provenance, declared in the row itself. [Authored]: an explicit
   keeper memory_write. [Injected]: librarian extraction — the row is a copy
   of something the keeper already saw, which is exactly the feed the
   self-referential reinjection loop runs on (task-1032 / rondo probes).
   [trace_id] is the committing write's trace when the writer knows one; empty
   means consult the snapshot journal. Category tokens only ever reach prompt
   renders — never a unique identity (masc#29558). *)
type origin_kind =
  | Authored
  | Injected

type origin =
  { kind : origin_kind
  ; trace_id : string
  }

let origin_kind_to_string = function
  | Authored -> "authored"
  | Injected -> "injected"
;;

let origin_of_json = function
  | `Assoc fields
    when exact_fields
           (wire_field_set [ wire_field_kind; wire_field_trace_id ])
           fields ->
    (match
       List.assoc_opt wire_field_kind fields
       , List.assoc_opt wire_field_trace_id fields
     with
     | Some (`String kind), Some (`String trace_id) ->
       (match kind with
        | "authored" -> Some { kind = Authored; trace_id }
        | "injected" -> Some { kind = Injected; trace_id }
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let origin_to_json (o : origin) =
  `Assoc
    [ wire_field_kind, `String (origin_kind_to_string o.kind)
    ; wire_field_trace_id, `String o.trace_id
    ]
;;

type derivation =
  { rule_id : string
  ; premise_ids : string list
  }

type basis =
  | Observed
  | Derived of derivation list

(* The fact carries the exact claim, its recalled category, and observable
   insertion/refresh timestamps. [first_seen]: insertion, authoritative,
   preserved across re-upsert. [last_seen]: most recent observation of the
   same claim bytes. [reinforcement]: how many times the exact claim bytes were
   re-observed — the measurable damper on the byte-identical reinjection loop:
   a re-injected row
   increments instead of accumulating a duplicate. A fact's value is the
   librarian's judgment, not a score or a model-invented semantic identity. *)
type fact =
  { claim : string
  ; category : category
  ; first_seen : float
  ; last_seen : float
  ; reinforcement : int
  ; origin : origin
  ; basis : basis
  }

(* ---------- JSON codecs ---------- *)

let json_string_field key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`String s) -> Some s
  | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null)
  | None -> None
;;

let json_float_field key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | Some (`Assoc _ | `Bool _ | `Intlit _ | `List _ | `Null | `String _) | None -> None
;;

let unique_non_empty_strings values =
  let rec loop seen = function
    | [] -> true
    | value :: rest ->
      if
        not (non_empty_string value)
        || Wire_field_set.mem value seen
      then false
      else loop (Wire_field_set.add value seen) rest
  in
  values <> [] && loop Wire_field_set.empty values
;;

let valid_derivation ({ rule_id; premise_ids } : derivation) =
  non_empty_string rule_id
  && unique_non_empty_strings premise_ids
  && List.for_all is_memory_id premise_ids
;;

let normalize_derivation ({ rule_id; premise_ids } : derivation) =
  { rule_id; premise_ids = List.sort String.compare premise_ids }
;;

let valid_derivations derivations =
  let rec loop rule_ids = function
    | [] -> true
    | derivation :: rest ->
      if
        not (valid_derivation derivation)
        || Wire_field_set.mem derivation.rule_id rule_ids
      then false
      else loop (Wire_field_set.add derivation.rule_id rule_ids) rest
  in
  derivations <> [] && loop Wire_field_set.empty derivations
;;

let derivation_to_json ({ rule_id; premise_ids } : derivation) =
  if not (valid_derivation { rule_id; premise_ids })
  then invalid_arg "memory derivation must name a rule and unique non-empty premises";
  let { rule_id; premise_ids } =
    normalize_derivation { rule_id; premise_ids }
  in
  `Assoc
    [ wire_field_rule_id, `String rule_id
    ; wire_field_premise_ids, `List (List.map (fun id -> `String id) premise_ids)
    ]
;;

let derivation_of_json = function
  | `Assoc fields
    when exact_fields
           (wire_field_set [ wire_field_rule_id; wire_field_premise_ids ])
           fields ->
    (match
       List.assoc_opt wire_field_rule_id fields
       , List.assoc_opt wire_field_premise_ids fields
     with
     | Some (`String rule_id), Some (`List values) ->
       let rec strings acc = function
         | [] -> Some (List.rev acc)
         | `String value :: rest -> strings (value :: acc) rest
         | _ -> None
       in
       (match strings [] values with
        | Some premise_ids when valid_derivation { rule_id; premise_ids } ->
          Some (normalize_derivation { rule_id; premise_ids })
        | Some _ | None -> None)
     | _ -> None)
  | _ -> None
;;

let basis_to_json = function
  | Observed -> `Assoc [ wire_field_kind, `String "observed" ]
  | Derived derivations ->
    if not (valid_derivations derivations)
    then invalid_arg "derived memory basis must carry valid derivations";
    `Assoc
      [ wire_field_kind, `String "derived"
      ; wire_field_derivations, `List (List.map derivation_to_json derivations)
      ]
;;

let basis_of_json = function
  | `Assoc fields
    when exact_fields (wire_field_set [ wire_field_kind ]) fields ->
    (match List.assoc_opt wire_field_kind fields with
     | Some (`String "observed") -> Some Observed
     | Some _ | None -> None)
  | `Assoc fields
    when exact_fields
           (wire_field_set [ wire_field_kind; wire_field_derivations ])
           fields ->
    (match
       List.assoc_opt wire_field_kind fields
       , List.assoc_opt wire_field_derivations fields
     with
     | Some (`String "derived"), Some (`List values) ->
       let rec derivations acc = function
         | [] -> Some (List.rev acc)
         | value :: rest ->
           (match derivation_of_json value with
            | Some derivation -> derivations (derivation :: acc) rest
            | None -> None)
       in
       (match derivations [] values with
        | Some derivations when valid_derivations derivations ->
          Some (Derived derivations)
        | Some _ | None -> None)
     | _ -> None)
  | _ -> None
;;

(* The exact claim bytes are the only memory-content authority. The digest is a
   bounded derived identifier for retention and observability; it does not
   normalize or classify prose. *)
let observed ~claim ~category ~now ~origin =
  { claim
  ; category
  ; first_seen = now
  ; last_seen = now
  ; reinforcement = 0
  ; origin
  ; basis = Observed
  }
;;

let derived ~claim ~category ~now ~origin ~derivations =
  if not (valid_derivations derivations)
  then Error "derived memory fact must carry unique valid rule derivations"
  else
    Ok
      { claim
      ; category
      ; first_seen = now
      ; last_seen = now
      ; reinforcement = 0
      ; origin
      ; basis = Derived (List.map normalize_derivation derivations)
      }
;;

let memory_id (f : fact) =
  memory_id_prefix ^ Digestif.SHA256.(digest_string f.claim |> to_hex)
;;

let fact_to_json (f : fact) =
  if not (non_empty_string f.claim)
  then invalid_arg "memory fact claim must be non-empty";
  if not (Float.is_finite f.first_seen)
  then invalid_arg "memory fact first_seen must be finite";
  if not (Float.is_finite f.last_seen)
  then invalid_arg "memory fact last_seen must be finite";
  if f.reinforcement < 0
  then invalid_arg "memory fact reinforcement must be non-negative";
  `Assoc
    [ wire_field_claim, `String f.claim
    ; wire_field_category, `String (category_to_string f.category)
    ; wire_field_first_seen, `Float f.first_seen
    ; wire_field_last_seen, `Float f.last_seen
    ; wire_field_reinforcement, `Int f.reinforcement
    ; wire_field_origin, origin_to_json f.origin
    ; wire_field_basis, basis_to_json f.basis
    ]
;;

(* Strict decoder for the closed canonical fact shape. *)
let current_fact fields =
  match
    ( json_string_field wire_field_claim fields
    , json_string_field wire_field_category fields
    , json_float_field wire_field_first_seen fields
    , json_float_field wire_field_last_seen fields
    , List.assoc_opt wire_field_reinforcement fields
    , List.assoc_opt wire_field_origin fields
    , List.assoc_opt wire_field_basis fields )
  with
  | ( Some claim
    , Some category_str
    , Some first_seen
    , Some last_seen
    , Some (`Int reinforcement)
    , Some origin_json
    , Some basis_json ) ->
    (match
       category_of_string category_str
       , origin_of_json origin_json
       , basis_of_json basis_json
     with
     | Some category, Some origin, Some basis
       when non_empty_string claim
            && Float.is_finite first_seen
            && Float.is_finite last_seen
            && reinforcement >= 0 ->
       Some { claim; category; first_seen; last_seen; reinforcement; origin; basis }
     | _ -> None)
  | _ -> None
;;

let fact_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields when exact_fields fact_wire_fields fields ->
    current_fact fields
  | `Assoc _
  | `Bool _
  | `Float _
  | `Int _
  | `Intlit _
  | `List _
  | `Null
  | `String _ -> None
;;
