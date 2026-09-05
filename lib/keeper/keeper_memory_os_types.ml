(** Keeper_memory_os_types — current Memory OS fact schema. *)

open Result.Syntax

(* Canonical JSON wire keys for Memory OS persistence and librarian ingestion.
   The schema module owns these strings so the parser, retry prompt, persistence
   codec, and tests cannot drift by maintaining parallel literal sets. *)
let wire_field_claim = "claim"
let wire_field_category = "category"
let wire_field_first_seen = "first_seen"
let wire_field_last_seen = "last_seen"
let wire_field_origin = "origin"
let wire_field_memory_id = "memory_id"
let wire_field_reason = "reason"
let wire_field_basis = "basis"
let wire_field_supersedes = "supersedes"
let wire_field_kind = "kind"
let wire_field_derivations = "derivations"
let wire_field_board = "board"
let wire_field_post_id = "post_id"
(** Optional librarian claim fields naming a Board source. *)
let wire_field_comment_id = "comment_id"
let wire_field_board_post_id = "board_post_id"
let wire_field_board_comment_id = "board_comment_id"
let wire_field_rule_id = "rule_id"
let wire_field_premise_ids = "premise_ids"
let wire_field_trace_id = "trace_id"

module Wire_field_set = Set.Make (String)

let wire_field_set fields =
  List.fold_left (fun set field -> Wire_field_set.add field set) Wire_field_set.empty fields
;;

(* ---------- Decode rejections ---------- *)

(** One step of the path to a rejected node, outermost first. A rejection that
    names only the document sends its reader back to re-deriving this decoder
    by hand, which is what the #32239 snapshot recovery had to do. *)
type wire_step =
  | Wire_field of string
  | Wire_index of int

(** Why one node did not decode. Closed, so a new rejection has to name itself
    here before a decoder can make it. Every constructor is produced by at
    least one site in this module or in {!Keeper_memory_os_current}. *)
type wire_reason =
  | Expected_object
  | Expected_array
  | Expected_string
  | Expected_int
  | Expected_number
  | Duplicate_field of string
  | Field_set_mismatch of
      { missing : string list
      ; unexpected : string list
      }
  | Unknown_token of string
      (** A closed vocabulary (category, origin kind, basis kind, source kind)
          does not contain this token. *)
  | Blank_string
  | Not_a_memory_id of string
  | Not_a_board_post_id of string
  | Not_a_board_comment_id of string
  | Not_finite
  | Negative
  | Not_positive
  | Empty_list
  | Not_ascending
  | Duplicate_entry of string

type wire_error =
  { path : wire_step list
  ; reason : wire_reason
  }

let wire_step_to_string = function
  | Wire_field name -> "." ^ name
  | Wire_index index -> Printf.sprintf "[%d]" index
;;

let wire_path_to_string path =
  match path with
  | [] -> "<root>"
  | _ :: _ ->
    let rendered = String.concat "" (List.map wire_step_to_string path) in
    (* The outermost step renders as ".facts"; the document root is implicit. *)
    if String.length rendered > 0 && rendered.[0] = '.'
    then String.sub rendered 1 (String.length rendered - 1)
    else rendered
;;

let wire_reason_to_string = function
  | Expected_object -> "expected a JSON object"
  | Expected_array -> "expected a JSON array"
  | Expected_string -> "expected a JSON string"
  | Expected_int -> "expected a JSON integer"
  | Expected_number -> "expected a JSON number"
  | Duplicate_field name -> Printf.sprintf "field %S appears more than once" name
  | Field_set_mismatch { missing; unexpected } ->
    Printf.sprintf
      "field set mismatch (missing: %s) (unexpected: %s)"
      (match missing with
       | [] -> "none"
       | _ :: _ -> String.concat "," missing)
      (match unexpected with
       | [] -> "none"
       | _ :: _ -> String.concat "," unexpected)
  | Unknown_token token -> Printf.sprintf "this build does not know the token %S" token
  | Blank_string -> "expected a non-blank string"
  | Not_a_memory_id value -> Printf.sprintf "expected a memory identity, got %S" value
  | Not_a_board_post_id value -> Printf.sprintf "expected a Board post id, got %S" value
  | Not_a_board_comment_id value ->
    Printf.sprintf "expected a Board comment id, got %S" value
  | Not_finite -> "expected a finite number"
  | Negative -> "expected a non-negative value"
  | Not_positive -> "expected a value of at least one"
  | Empty_list -> "expected a non-empty array"
  | Not_ascending -> "expected entries in strictly ascending order"
  | Duplicate_entry identity -> Printf.sprintf "identity %s appears more than once" identity
;;

let wire_error_to_string { path; reason } =
  Printf.sprintf "%s: %s" (wire_path_to_string path) (wire_reason_to_string reason)
;;

let wire_fail path reason = Error { path; reason }
let wire_here reason = Error { path = []; reason }

(** Prefix [step] onto the path of a rejection produced by a nested decoder, so
    each decoder reports a path relative to itself and the caller places it. *)
let wire_at step = function
  | Ok _ as ok -> ok
  | Error error -> Error { error with path = step :: error.path }
;;

(** Why [fields] is not exactly the closed set [allowed], or [None] when it is.
    A repeated key is reported on its own because it leaves both difference
    sets empty while still being a rejection. *)
let field_set_rejection allowed fields =
  let rec duplicate seen = function
    | [] -> None
    | (name, _) :: rest ->
      if Wire_field_set.mem name seen
      then Some (Duplicate_field name)
      else duplicate (Wire_field_set.add name seen) rest
  in
  match duplicate Wire_field_set.empty fields with
  | Some _ as rejection -> rejection
  | None ->
    let observed =
      List.fold_left
        (fun set (name, _) -> Wire_field_set.add name set)
        Wire_field_set.empty
        fields
    in
    let missing = Wire_field_set.(elements (diff allowed observed)) in
    let unexpected = Wire_field_set.(elements (diff observed allowed)) in
    (match missing, unexpected with
     | [], [] -> None
     | _, _ -> Some (Field_set_mismatch { missing; unexpected }))
;;

(** [field_set_rejection] as a result, for decoders that reject and stop. *)
let exact_fields_result allowed fields =
  match field_set_rejection allowed fields with
  | None -> Ok ()
  | Some reason -> wire_here reason
;;

(** {!exact_fields_result} for callers that name the closed set as a list. *)
let exact_field_names_result names fields =
  exact_fields_result (wire_field_set names) fields
;;

(* Field readers used after [exact_fields_result] has proven the field set.
   Absence is still reported rather than asserted away: the two checks
   disagreeing is a rejection like any other, not a reason to raise. *)

let wire_string_field key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> Ok value
  | Some _ -> wire_fail [ Wire_field key ] Expected_string
  | None -> wire_fail [] (Field_set_mismatch { missing = [ key ]; unexpected = [] })
;;

let wire_int_field key fields =
  match List.assoc_opt key fields with
  | Some (`Int value) -> Ok value
  | Some _ -> wire_fail [ Wire_field key ] Expected_int
  | None -> wire_fail [] (Field_set_mismatch { missing = [ key ]; unexpected = [] })
;;

let wire_number_field key fields =
  match List.assoc_opt key fields with
  | Some (`Float value) -> Ok value
  | Some (`Int value) -> Ok (float_of_int value)
  | Some _ -> wire_fail [ Wire_field key ] Expected_number
  | None -> wire_fail [] (Field_set_mismatch { missing = [ key ]; unexpected = [] })
;;

let wire_list_field key fields =
  match List.assoc_opt key fields with
  | Some (`List values) -> Ok values
  | Some _ -> wire_fail [ Wire_field key ] Expected_array
  | None -> wire_fail [] (Field_set_mismatch { missing = [ key ]; unexpected = [] })
;;

let wire_json_field key fields =
  match List.assoc_opt key fields with
  | Some json -> Ok json
  | None -> wire_fail [] (Field_set_mismatch { missing = [ key ]; unexpected = [] })
;;

(** Place a nested rejection at [field]'s [index] element. *)
let wire_at_element field index result =
  wire_at (Wire_field field) (wire_at (Wire_index index) result)
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
    ; wire_field_origin
    ; wire_field_basis
    ]
;;

let wire_librarian_claim_fields =
  [ wire_field_claim
  ; wire_field_category
  ; wire_field_board_post_id
  ; wire_field_board_comment_id
  ; wire_field_supersedes
  ]
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
  | `Assoc fields ->
    let* () =
      exact_fields_result (wire_field_set wire_librarian_dropped_fields) fields
    in
    let* memory_id = wire_string_field wire_field_memory_id fields in
    let* reason = wire_string_field wire_field_reason fields in
    let* () =
      if is_memory_id memory_id
      then Ok ()
      else wire_fail [ Wire_field wire_field_memory_id ] (Not_a_memory_id memory_id)
    in
    let+ () =
      if non_empty_string reason
      then Ok ()
      else wire_fail [ Wire_field wire_field_reason ] Blank_string
    in
    { memory_id; reason }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
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
   self-referential reinjection loop runs on (task-1032 probes).
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
  | `Assoc fields ->
    let* () =
      exact_fields_result
        (wire_field_set [ wire_field_kind; wire_field_trace_id ])
        fields
    in
    let* kind = wire_string_field wire_field_kind fields in
    let* trace_id = wire_string_field wire_field_trace_id fields in
    (match kind with
     | "authored" -> Ok { kind = Authored; trace_id }
     | "injected" -> Ok { kind = Injected; trace_id }
     | _ -> wire_fail [ Wire_field wire_field_kind ] (Unknown_token kind))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
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

type board_ref =
  { post_id : Board_types.Post_id.t
  ; comment_id : Board_types.Comment_id.t option
  }

type observation =
  | Transcript
  | Board of board_ref

type basis =
  | Observed of observation
  | Derived of derivation list

(* The fact carries the exact claim, its recalled category, and observable
   insertion/refresh timestamps. [first_seen]: insertion, authoritative,
   preserved across re-upsert. [last_seen]: most recent observation of the
   same claim bytes; a re-observation refreshes it and adds no row, and is
   not a strength signal (RFC-0418). A fact's value is the librarian's
   judgment, not a score or a model-invented semantic identity. *)
type fact =
  { claim : string
  ; category : category
  ; first_seen : float
  ; last_seen : float
  ; origin : origin
  ; basis : basis
  }

(* ---------- JSON codecs ---------- *)

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

(* [valid_derivation] answers a bool. A stored derivation this build refuses
   has to say which of the three constraints it broke, so the same predicate is
   spelled again as a rejection. Accept/reject sets are identical; only the
   order in which reasons are reported differs. *)
let derivation_rejection ~rule_id ~premise_ids =
  if not (non_empty_string rule_id)
  then wire_fail [ Wire_field wire_field_rule_id ] Blank_string
  else (
    match premise_ids with
    | [] -> wire_fail [ Wire_field wire_field_premise_ids ] Empty_list
    | _ :: _ ->
      let rec check index seen = function
        | [] -> Ok ()
        | premise_id :: rest ->
          let at reason =
            wire_fail [ Wire_field wire_field_premise_ids; Wire_index index ] reason
          in
          if Wire_field_set.mem premise_id seen
          then at (Duplicate_entry premise_id)
          else if not (is_memory_id premise_id)
          then at (Not_a_memory_id premise_id)
          else check (index + 1) (Wire_field_set.add premise_id seen) rest
      in
      check 0 Wire_field_set.empty premise_ids)
;;

let derivation_of_json = function
  | `Assoc fields ->
    let* () =
      exact_fields_result
        (wire_field_set [ wire_field_rule_id; wire_field_premise_ids ])
        fields
    in
    let* rule_id = wire_string_field wire_field_rule_id fields in
    let* values = wire_list_field wire_field_premise_ids fields in
    let rec strings index acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> strings (index + 1) (value :: acc) rest
      | _ :: _ ->
        wire_fail
          [ Wire_field wire_field_premise_ids; Wire_index index ]
          Expected_string
    in
    let* premise_ids = strings 0 [] values in
    let+ () = derivation_rejection ~rule_id ~premise_ids in
    normalize_derivation { rule_id; premise_ids }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

(* The Board owns its id grammar; Memory OS keeps the Board's parsed identity
   rather than a string that passed once. Existence is not checked here: a
   reference names what was cited. No reader revalidates it yet; RFC-0402
   piece 2 does so at recall. *)
let board_ref_of_ids ~post_id ~comment_id =
  match Board_types.Post_id.of_string post_id with
  | Error _ -> wire_fail [ Wire_field wire_field_post_id ] (Not_a_board_post_id post_id)
  | Ok post_id ->
    (match comment_id with
     | None -> Ok { post_id; comment_id = None }
     | Some comment_id ->
       (match Board_types.Comment_id.of_string comment_id with
        | Error _ ->
          wire_fail
            [ Wire_field wire_field_comment_id ]
            (Not_a_board_comment_id comment_id)
        | Ok comment_id -> Ok { post_id; comment_id = Some comment_id }))
;;

let board_ref_to_json (board : board_ref) =
  `Assoc
    ((wire_field_post_id, `String (Board_types.Post_id.to_string board.post_id))
     :: (match board.comment_id with
         | None -> []
         | Some comment_id ->
           [ wire_field_comment_id, `String (Board_types.Comment_id.to_string comment_id) ]))
;;

let board_ref_of_json = function
  | `Assoc fields ->
    let* () =
      match List.assoc_opt wire_field_comment_id fields with
      | None -> exact_fields_result (wire_field_set [ wire_field_post_id ]) fields
      | Some _ ->
        exact_fields_result
          (wire_field_set [ wire_field_post_id; wire_field_comment_id ])
          fields
    in
    let* post_id = wire_string_field wire_field_post_id fields in
    let* comment_id =
      match List.assoc_opt wire_field_comment_id fields with
      | None -> Ok None
      | Some _ ->
        let* comment_id = wire_string_field wire_field_comment_id fields in
        Ok (Some comment_id)
    in
    board_ref_of_ids ~post_id ~comment_id
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

let basis_to_json = function
  | Observed Transcript -> `Assoc [ wire_field_kind, `String "observed" ]
  | Observed (Board board) ->
    `Assoc
      [ wire_field_kind, `String "observed"
      ; wire_field_board, board_ref_to_json board
      ]
  | Derived derivations ->
    if not (valid_derivations derivations)
    then invalid_arg "derived memory basis must carry valid derivations";
    `Assoc
      [ wire_field_kind, `String "derived"
      ; wire_field_derivations, `List (List.map derivation_to_json derivations)
      ]
;;

(* What [valid_derivations] still checks once every element has decoded: the
   list is non-empty and no rule identity repeats. *)
let derivations_rejection derivations =
  match derivations with
  | [] -> wire_fail [ Wire_field wire_field_derivations ] Empty_list
  | _ :: _ ->
    let rec check index seen = function
      | [] -> Ok ()
      | derivation :: rest ->
        if Wire_field_set.mem derivation.rule_id seen
        then
          wire_fail
            [ Wire_field wire_field_derivations
            ; Wire_index index
            ; Wire_field wire_field_rule_id
            ]
            (Duplicate_entry derivation.rule_id)
        else check (index + 1) (Wire_field_set.add derivation.rule_id seen) rest
    in
    check 0 Wire_field_set.empty derivations
;;

(* The kind token, not the field set, chooses the shape. Dispatching on the
   field set instead reported a missing [derivations] list as an unknown
   basis. *)
let basis_of_json = function
  | `Assoc fields ->
    let* kind = wire_string_field wire_field_kind fields in
    (match kind with
     | "observed" ->
       (match List.assoc_opt wire_field_board fields with
        | None ->
          let+ () = exact_fields_result (wire_field_set [ wire_field_kind ]) fields in
          Observed Transcript
        | Some board_json ->
          let* () =
            exact_fields_result
              (wire_field_set [ wire_field_kind; wire_field_board ])
              fields
          in
          let+ board =
            wire_at (Wire_field wire_field_board) (board_ref_of_json board_json)
          in
          Observed (Board board))
     | "derived" ->
       let* () =
         exact_fields_result
           (wire_field_set [ wire_field_kind; wire_field_derivations ])
           fields
       in
       let* values = wire_list_field wire_field_derivations fields in
       let rec decode index acc = function
         | [] -> Ok (List.rev acc)
         | value :: rest ->
           let* derivation =
             wire_at_element wire_field_derivations index (derivation_of_json value)
           in
           decode (index + 1) (derivation :: acc) rest
       in
       let* derivations = decode 0 [] values in
       let+ () = derivations_rejection derivations in
       Derived derivations
     | _ -> wire_fail [ Wire_field wire_field_kind ] (Unknown_token kind))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

(* The exact claim bytes are the only memory-content authority. The digest is a
   bounded derived identifier for retention and observability; it does not
   normalize or classify prose. *)
let observed ~claim ~category ~now ~origin =
  { claim
  ; category
  ; first_seen = now
  ; last_seen = now
  ; origin
  ; basis = Observed Transcript
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
  `Assoc
    [ wire_field_claim, `String f.claim
    ; wire_field_category, `String (category_to_string f.category)
    ; wire_field_first_seen, `Float f.first_seen
    ; wire_field_last_seen, `Float f.last_seen
    ; wire_field_origin, origin_to_json f.origin
    ; wire_field_basis, basis_to_json f.basis
    ]
;;

(* Strict decoder for the closed canonical fact shape. *)
let current_fact fields =
  let* claim = wire_string_field wire_field_claim fields in
  let* category_token = wire_string_field wire_field_category fields in
  let* first_seen = wire_number_field wire_field_first_seen fields in
  let* last_seen = wire_number_field wire_field_last_seen fields in
  let* origin_json = wire_json_field wire_field_origin fields in
  let* basis_json = wire_json_field wire_field_basis fields in
  let* category =
    match category_of_string category_token with
    | Some category -> Ok category
    | None -> wire_fail [ Wire_field wire_field_category ] (Unknown_token category_token)
  in
  let* origin = wire_at (Wire_field wire_field_origin) (origin_of_json origin_json) in
  let* basis = wire_at (Wire_field wire_field_basis) (basis_of_json basis_json) in
  let* () =
    if non_empty_string claim
    then Ok ()
    else wire_fail [ Wire_field wire_field_claim ] Blank_string
  in
  let* () =
    if Float.is_finite first_seen
    then Ok ()
    else wire_fail [ Wire_field wire_field_first_seen ] Not_finite
  in
  let+ () =
    if Float.is_finite last_seen
    then Ok ()
    else wire_fail [ Wire_field wire_field_last_seen ] Not_finite
  in
  { claim; category; first_seen; last_seen; origin; basis }
;;

let fact_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    let* () = exact_fields_result fact_wire_fields fields in
    current_fact fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;
