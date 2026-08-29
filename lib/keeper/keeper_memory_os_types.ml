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

(* The canonical persisted fact shape. [legacy_fact_wire_fields] is the
   pre-provenance three-field shape: rows written before
   origin/last_seen/reinforcement existed decode as [Legacy] origin rather
   than being rejected, so this widening never orphans the snapshot already
   on disk. A row mixing the two vocabularies rejects below. *)
let fact_wire_fields =
  wire_field_set
    [ wire_field_claim
    ; wire_field_category
    ; wire_field_first_seen
    ; wire_field_last_seen
    ; wire_field_reinforcement
    ; wire_field_origin
    ]
;;

let legacy_fact_wire_fields =
  wire_field_set [ wire_field_claim; wire_field_category; wire_field_first_seen ]
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
     | Some (`String memory_id), Some (`String reason) ->
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
   [Legacy]: rows written before this field existed; provenance is unknown
   and must not be back-filled with a guess. [trace_id] is the committing
   write's trace when the writer knows one; empty means consult the snapshot
   journal. Category tokens only ever reach prompt renders — never a unique
   identity (masc#29558). *)
type origin_kind =
  | Authored
  | Injected
  | Legacy

type origin =
  { kind : origin_kind
  ; trace_id : string
  }

let origin_kind_to_string = function
  | Authored -> "authored"
  | Injected -> "injected"
  | Legacy -> "legacy"
;;

let origin_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields, List.assoc_opt "trace_id" fields with
     | Some (`String kind), Some (`String trace_id) ->
       (match kind with
        | "authored" -> Some { kind = Authored; trace_id }
        | "injected" -> Some { kind = Injected; trace_id }
        | "legacy" -> Some { kind = Legacy; trace_id }
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let origin_to_json (o : origin) =
  `Assoc
    [ "kind", `String (origin_kind_to_string o.kind)
    ; "trace_id", `String o.trace_id
    ]
;;

(* The fact carries the exact claim, its recalled category, and observable
   insertion/refresh timestamps. [first_seen]: insertion, authoritative,
   preserved across re-upsert. [last_seen]: most recent observation of the
   same claim bytes — the eviction ordering key, so a row that keeps proving
   relevant outlives budget pressure instead of dying of age. [reinforcement]:
   how many times the exact claim bytes were re-observed — the measurable
   damper on the byte-identical reinjection loop: a re-injected row
   increments instead of accumulating a duplicate. A fact's value is the
   librarian's judgment, not a score or a model-invented semantic identity. *)
type fact =
  { claim : string
  ; category : category
  ; first_seen : float
  ; last_seen : float
  ; reinforcement : int
  ; origin : origin
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

let non_empty_string value = not (String.equal (String.trim value) "")

(* The exact claim bytes are the only memory-content authority. The digest is a
   bounded derived identifier for retention and observability; it does not
   normalize or classify prose. *)
let memory_id (f : fact) =
  "sha256:" ^ Digestif.SHA256.(digest_string f.claim |> to_hex)
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
    ]
;;

(* Strict decoders for the closed canonical fact shapes. The current
   six-field row and the legacy three-field row are both closed sets; a row
   mixing the vocabularies (origin without last_seen, or vice versa) is a
   shape this build does not know and rejects rather than reading past. *)
let legacy_fact fields =
  match
    ( json_string_field wire_field_claim fields
    , json_string_field wire_field_category fields
    , json_float_field wire_field_first_seen fields )
  with
  | Some claim, Some category_str, Some first_seen ->
    (match category_of_string category_str with
     | None -> None
     | Some category when non_empty_string claim && Float.is_finite first_seen ->
       Some
         { claim
         ; category
         ; first_seen
         ; last_seen = first_seen
         ; reinforcement = 0
         ; origin = { kind = Legacy; trace_id = "" }
         }
     | Some _ -> None)
  | _ -> None
;;

let current_fact fields =
  match
    ( json_string_field wire_field_claim fields
    , json_string_field wire_field_category fields
    , json_float_field wire_field_first_seen fields
    , json_float_field wire_field_last_seen fields
    , List.assoc_opt wire_field_reinforcement fields
    , List.assoc_opt wire_field_origin fields )
  with
  | ( Some claim
    , Some category_str
    , Some first_seen
    , Some last_seen
    , Some (`Int reinforcement)
    , Some origin_json ) ->
    (match category_of_string category_str, origin_of_json origin_json with
     | Some category, Some origin
       when non_empty_string claim
            && Float.is_finite first_seen
            && Float.is_finite last_seen
            && reinforcement >= 0 ->
       Some { claim; category; first_seen; last_seen; reinforcement; origin }
     | _ -> None)
  | _ -> None
;;

(* A dispatch between two closed shapes needs set equality, not a subset
   check: a legacy three-field row is also a subset of the current
   vocabulary, so [closed_fields] alone steered it into [current_fact],
   where it died without the legacy arm ever being consulted. *)
let exact_fields allowed fields =
  closed_fields allowed fields
  && List.length fields = Wire_field_set.cardinal allowed
;;

let fact_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields when exact_fields fact_wire_fields fields ->
    current_fact fields
  | `Assoc fields when exact_fields legacy_fact_wire_fields fields ->
    legacy_fact fields
  | `Assoc _
  | `Bool _
  | `Float _
  | `Int _
  | `Intlit _
  | `List _
  | `Null
  | `String _ -> None
;;
