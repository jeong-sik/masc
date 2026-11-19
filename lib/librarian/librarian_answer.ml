open Keeper_memory_os_types

type new_fact =
  { claim : string
  ; category : category
  ; observation : observation
  ; from_units : string list
  }

type op =
  | Add of new_fact
  | Drop of
      { ref_ : string
      ; reason : string
      }
  | Merge of
      { refs : string list
      ; into : new_fact
      }
  | Revise of
      { ref_ : string
      ; into : new_fact
      }
  | Seen of
      { ref_ : string
      ; from_units : string list
      }

type working_state =
  | Keep
  | Set of string

type t =
  { question : Librarian_question_id.t
  ; ops : op list
  ; working_state : working_state
  }

type rejection =
  | Not_json
  | Schema_violation of wire_error
  | Echo_mismatch
  | Empty_or_partial

let rejection_kind = function
  | Not_json -> "not_json"
  | Schema_violation _ -> "schema_violation"
  | Echo_mismatch -> "echo_mismatch"
  | Empty_or_partial -> "empty_or_partial"
;;

let field_question = "question"
let field_question_end = "question_end"
let field_working_state = "working_state"
let field_ops = "ops"
let field_op = "op"
let field_claim = wire_field_claim
let field_category = wire_field_category
let field_basis = wire_field_basis
let field_from = "from"
let field_ref = "ref"
let field_refs = "refs"
let field_reason = wire_field_reason

type op_kind =
  | Kind_add
  | Kind_drop
  | Kind_merge
  | Kind_revise
  | Kind_seen

let op_kinds = [ Kind_add; Kind_drop; Kind_merge; Kind_revise; Kind_seen ]

let op_kind_token = function
  | Kind_add -> "add"
  | Kind_drop -> "drop"
  | Kind_merge -> "merge"
  | Kind_revise -> "revise"
  | Kind_seen -> "seen"
;;

let op_kind_of_token token =
  List.find_opt (fun kind -> String.equal (op_kind_token kind) token) op_kinds
;;

let op_field kind = field_op, `String (op_kind_token kind)
let new_fact_fields = [ field_claim; field_category; field_basis; field_from ]
let units_json names = `List (List.map (fun unit_name -> `String unit_name) names)

let new_fact_to_fields (fact : new_fact) =
  [ field_claim, `String fact.claim
  ; field_category, `String (category_to_string fact.category)
  ; field_basis, basis_to_json (Observed fact.observation)
  ; field_from, units_json fact.from_units
  ]
;;

let op_to_json = function
  | Add fact -> `Assoc (op_field Kind_add :: new_fact_to_fields fact)
  | Drop { ref_; reason } ->
    `Assoc [ op_field Kind_drop; field_ref, `String ref_; field_reason, `String reason ]
  | Merge { refs; into } ->
    `Assoc
      (op_field Kind_merge
       :: (field_refs, `List (List.map (fun name -> `String name) refs))
       :: new_fact_to_fields into)
  | Revise { ref_; into } ->
    `Assoc (op_field Kind_revise :: (field_ref, `String ref_) :: new_fact_to_fields into)
  | Seen { ref_; from_units } ->
    `Assoc [ op_field Kind_seen; field_ref, `String ref_; field_from, units_json from_units ]
;;

let to_json answer =
  `Assoc
    [ field_question, `String answer.question.front
    ; field_question_end, `String answer.question.back
    ; ( field_working_state
      , match answer.working_state with
        | Keep -> `Null
        | Set text -> `String text )
    ; field_ops, `List (List.map op_to_json answer.ops)
    ]
;;

let ( let* ) = Result.bind

let nonblank_field field fields =
  let* value = wire_string_field field fields in
  if String.equal (String.trim value) ""
  then wire_fail [ Wire_field field ] Blank_string
  else Ok value
;;

(* Names are kept as written. Only what no table could resolve is refused
   here: a value that is not a string, or a blank one. *)
let names_field field fields =
  let* items = wire_list_field field fields in
  let rec collect index names = function
    | [] -> Ok (List.rev names)
    | `String name :: rest ->
      if String.equal (String.trim name) ""
      then wire_at_element field index (wire_here Blank_string)
      else collect (index + 1) (name :: names) rest
    | (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null) :: _ ->
      wire_at_element field index (wire_here Expected_string)
  in
  collect 0 [] items
;;

let first_repeated names =
  let rec scan seen = function
    | [] -> None
    | name :: rest ->
      if Set_util.StringSet.mem name seen
      then Some name
      else scan (Set_util.StringSet.add name seen) rest
  in
  scan Set_util.StringSet.empty names
;;

let new_fact_of_fields fields =
  let* claim = nonblank_field field_claim fields in
  let* category_token = wire_string_field field_category fields in
  let* category =
    match category_of_string category_token with
    | Some category -> Ok category
    | None -> wire_fail [ Wire_field field_category ] (Unknown_token category_token)
  in
  let* basis_json = wire_json_field field_basis fields in
  let* basis = wire_at (Wire_field field_basis) (basis_of_json basis_json) in
  let* observation =
    match basis with
    | Observed observation -> Ok observation
    | Derived _ ->
      wire_fail [ Wire_field field_basis; Wire_field wire_field_kind ] (Unknown_token "derived")
  in
  let* from_units = names_field field_from fields in
  Ok { claim; category; observation; from_units }
;;

let op_of_json = function
  | `Assoc fields ->
    let* token = wire_string_field field_op fields in
    (match op_kind_of_token token with
     | None -> wire_fail [ Wire_field field_op ] (Unknown_token token)
     | Some Kind_add ->
       let* () = exact_field_names_result (field_op :: new_fact_fields) fields in
       let* fact = new_fact_of_fields fields in
       Ok (Add fact)
     | Some Kind_drop ->
       let* () = exact_field_names_result [ field_op; field_ref; field_reason ] fields in
       let* ref_ = nonblank_field field_ref fields in
       let* reason = nonblank_field field_reason fields in
       Ok (Drop { ref_; reason })
     | Some Kind_merge ->
       let* () =
         exact_field_names_result (field_op :: field_refs :: new_fact_fields) fields
       in
       let* refs = names_field field_refs fields in
       let* () =
         match refs, first_repeated refs with
         | [], _ -> wire_fail [ Wire_field field_refs ] Empty_list
         | _ :: _, Some name -> wire_fail [ Wire_field field_refs ] (Duplicate_entry name)
         | _ :: _, None -> Ok ()
       in
       let* into = new_fact_of_fields fields in
       Ok (Merge { refs; into })
     | Some Kind_revise ->
       let* () =
         exact_field_names_result (field_op :: field_ref :: new_fact_fields) fields
       in
       let* ref_ = nonblank_field field_ref fields in
       let* into = new_fact_of_fields fields in
       Ok (Revise { ref_; into })
     | Some Kind_seen ->
       let* () = exact_field_names_result [ field_op; field_ref; field_from ] fields in
       let* ref_ = nonblank_field field_ref fields in
       let* from_units = names_field field_from fields in
       (* Seen again says where. Without a unit it is the question's own
          Memory read back, which is no observation. *)
       (match from_units with
        | [] -> wire_fail [ Wire_field field_from ] Empty_list
        | _ :: _ -> Ok (Seen { ref_; from_units })))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

let ops_of_fields fields =
  let* items = wire_list_field field_ops fields in
  let rec collect index ops = function
    | [] -> Ok (List.rev ops)
    | item :: rest ->
      let* op = wire_at_element field_ops index (op_of_json item) in
      collect (index + 1) (op :: ops) rest
  in
  collect 0 [] items
;;

let working_state_of_fields fields =
  let* json = wire_json_field field_working_state fields in
  match json with
  | `Null -> Ok Keep
  | `String text -> Ok (Set text)
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ ->
    wire_fail [ Wire_field field_working_state ] Expected_string
;;

let of_json ~(asked : Librarian_question_id.t) json =
  let schema result = Result.map_error (fun error -> Schema_violation error) result in
  match json with
  | `Assoc fields ->
    let* () =
      schema
        (exact_field_names_result
           [ field_question; field_question_end; field_working_state; field_ops ]
           fields)
    in
    let* front = schema (wire_string_field field_question fields) in
    let* back = schema (wire_string_field field_question_end fields) in
    if not (String.equal front asked.front && String.equal back asked.back)
    then Error Echo_mismatch
    else
      let* working_state = schema (working_state_of_fields fields) in
      let* ops = schema (ops_of_fields fields) in
      Ok { question = asked; ops; working_state }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    schema (wire_here Expected_object)
;;

let of_string ~asked text =
  if String.equal (String.trim text) ""
  then Error Empty_or_partial
  else (
    (* Parsed as written. A helper that repairs the text first would turn a
       damaged answer into a different, accepted one. *)
    match Yojson.Safe.from_string text with
    | exception Yojson.Json_error (_ : string) -> Error Not_json
    | json -> of_json ~asked json)
;;
