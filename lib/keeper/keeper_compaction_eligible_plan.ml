module History = Keeper_compaction_eligible_history

type t = History.decision list

type decision_issue =
  | Expected_object
  | Unknown_field of string
  | Duplicate_field of string
  | Missing_field of string
  | Invalid_unit_index
  | Invalid_action
  | Invalid_summary
  | Missing_summary
  | Unexpected_summary
  | Empty_summary
  | Unknown_unit of int

type decode_error =
  | Expected_plan_object
  | Unknown_plan_field of string
  | Duplicate_plan_field of string
  | Missing_plan_field of string
  | Decisions_not_array
  | Invalid_decision of
      { position : int
      ; issue : decision_issue
      }
  | Invalid_binding of History.apply_error

type action =
  | Keep
  | Drop
  | Summarize

let field_decisions = "decisions"
let field_unit_index = "unit_index"
let field_action = "action"
let field_summary = "summary"
let action_keep = "keep"
let action_drop = "drop"
let action_summarize = "summarize"
let ( let* ) = Result.bind

let object_schema ~required properties =
  `Assoc
    [ "type", `String "object"
    ; "additionalProperties", `Bool false
    ; "properties", `Assoc properties
    ; "required", `List (List.map (fun field -> `String field) required)
    ]
;;

let output_schema =
  let decision =
    object_schema
      ~required:[ field_unit_index; field_action; field_summary ]
      [ field_unit_index, `Assoc [ "type", `String "integer" ]
      ; ( field_action
        , `Assoc
            [ "type", `String "string"
            ; ( "enum"
              , `List
                  [ `String action_keep
                  ; `String action_drop
                  ; `String action_summarize
                  ] )
            ] )
      ; ( field_summary
        , `Assoc
            [ "type", `List [ `String "string"; `String "null" ] ] )
      ]
  in
  object_schema
    ~required:[ field_decisions ]
    [ field_decisions
    , `Assoc [ "type", `String "array"; "items", decision ]
    ]
;;

let input_json source =
  let role = function
    | History.User -> "user"
    | History.Assistant -> "assistant"
  in
  History.eligible_units source
  |> List.map (fun unit ->
    `Assoc
      [ field_unit_index, `Int (History.unit_index unit)
      ; "role", `String (role (History.unit_role unit))
      ; ( "text_blocks"
        , `List
            (List.map
               (fun text -> `String text)
               (History.unit_text_blocks unit)) )
      ])
  |> fun units -> `List units
;;

let find_unique ~missing ~duplicate field fields =
  match List.filter (fun (name, _) -> String.equal name field) fields with
  | [] -> Error missing
  | [ _, value ] -> Ok value
  | _ -> Error duplicate
;;

let unknown_field allowed fields =
  List.find_map
    (fun (name, _) ->
       if List.exists (String.equal name) allowed then None else Some name)
    fields
;;

let eligible_unit source index =
  History.eligible_units source
  |> List.find_opt (fun unit -> Int.equal index (History.unit_index unit))
;;

let decode_decision ~source ~position = function
  | `Assoc fields ->
    (match
       unknown_field [ field_unit_index; field_action; field_summary ] fields
     with
     | Some field -> Error (Invalid_decision { position; issue = Unknown_field field })
     | None ->
       let invalid issue = Error (Invalid_decision { position; issue }) in
       let* index_json =
         find_unique
           ~missing:(Invalid_decision { position; issue = Missing_field field_unit_index })
           ~duplicate:
             (Invalid_decision { position; issue = Duplicate_field field_unit_index })
           field_unit_index
           fields
       in
       let* index =
         match index_json with
         | `Int value -> Ok value
         | _ -> invalid Invalid_unit_index
       in
       let* unit =
         match eligible_unit source index with
         | Some unit -> Ok unit
         | None -> invalid (Unknown_unit index)
       in
       let* action_json =
         find_unique
           ~missing:(Invalid_decision { position; issue = Missing_field field_action })
           ~duplicate:(Invalid_decision { position; issue = Duplicate_field field_action })
           field_action
           fields
       in
       let* action =
         match action_json with
         | `String value when String.equal value action_keep -> Ok Keep
         | `String value when String.equal value action_drop -> Ok Drop
         | `String value when String.equal value action_summarize -> Ok Summarize
         | _ -> invalid Invalid_action
       in
       let* summary_json =
         find_unique
           ~missing:(Invalid_decision { position; issue = Missing_field field_summary })
           ~duplicate:
             (Invalid_decision { position; issue = Duplicate_field field_summary })
           field_summary
           fields
       in
       let* summary =
         match summary_json with
         | `Null -> Ok None
         | `String value -> Ok (Some value)
         | _ -> invalid Invalid_summary
       in
       (match action, summary with
        | Keep, None -> Ok (History.keep unit)
        | Drop, None -> Ok (History.drop unit)
        | Summarize, None -> invalid Missing_summary
        | (Keep | Drop), Some _ -> invalid Unexpected_summary
        | Summarize, Some value ->
          (match History.Summary.create value with
           | Ok summary -> Ok (History.summarize unit summary)
           | Error History.Summary.Empty -> invalid Empty_summary)))
  | _ -> Error (Invalid_decision { position; issue = Expected_object })
;;

let decode ~source = function
  | `Assoc fields ->
    (match unknown_field [ field_decisions ] fields with
     | Some field -> Error (Unknown_plan_field field)
     | None ->
       let* decisions_json =
         find_unique
           ~missing:(Missing_plan_field field_decisions)
           ~duplicate:(Duplicate_plan_field field_decisions)
           field_decisions
           fields
       in
       let* items =
         match decisions_json with
         | `List items -> Ok items
         | _ -> Error Decisions_not_array
       in
       let rec collect position decisions = function
         | [] -> Ok (List.rev decisions)
         | item :: rest ->
           let* decision = decode_decision ~source ~position item in
           collect (position + 1) (decision :: decisions) rest
       in
       let* decisions = collect 0 [] items in
       (match History.apply source decisions with
        | Ok _ -> Ok decisions
        | Error error -> Error (Invalid_binding error)))
  | _ -> Error Expected_plan_object
;;

let apply ~source plan = History.apply source plan
