(** Keeper_memory_os_types — current Memory OS fact schema. *)

(* Canonical JSON wire keys for Memory OS persistence and librarian ingestion.
   The schema module owns these strings so the parser, retry prompt, persistence
   codec, and tests cannot drift by maintaining parallel literal sets. *)
let wire_field_claim = "claim"
let wire_field_category = "category"
let wire_field_first_seen = "first_seen"
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

let fact_wire_fields =
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

(* The fact carries the exact claim, its recalled category, and an observable
   insertion timestamp. A fact's value is the librarian's judgment, not a score
   or a model-invented semantic identity. *)
type fact =
  { claim : string
  ; category : category
  ; first_seen : float
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
  `Assoc
    [ wire_field_claim, `String f.claim
    ; wire_field_category, `String (category_to_string f.category)
    ; wire_field_first_seen, `Float f.first_seen
    ]
;;

(* Strict decoder for the closed canonical fact shape. *)
let fact_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields when closed_fields fact_wire_fields fields ->
    (match
       ( json_string_field wire_field_claim fields
       , json_string_field wire_field_category fields
       , json_float_field wire_field_first_seen fields )
     with
     | Some claim, Some category_str, Some first_seen ->
       (match category_of_string category_str with
        | None -> None
        | Some category when non_empty_string claim && Float.is_finite first_seen ->
          Some { claim; category; first_seen }
        | Some _ -> None)
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
