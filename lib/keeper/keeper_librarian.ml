(** Keeper_librarian — working-context pass contract and shared tool-observation types. *)

module String_set = Set.Make (String)

type object_field_error =
  | Unexpected_object_field of string
  | Duplicate_object_field of string

type tool_observation_outcome =
  | Succeeded
  | Failed
  | Unknown

type tool_observation =
  { tool_name : string
  ; outcome : tool_observation_outcome
  }

type goal_context =
  | No_task
  | Task_goals of
      { task_id : string
      ; criteria : ((string * Goal_phase.t * Goal_store.criterion) list, string) result
      }

type input =
  { turn_ref : Ids.Turn_ref.t
  ; goal_context : goal_context
  ; keeper_id : Keeper_identity.Keeper_id.t
  ; keeper_instructions : string
  ; working_context : Keeper_librarian_context.input
  }

let wire_field_working_contexts = "working_contexts"

let trim_nonempty = String_util.trim_nonempty

let format_keeper_instructions_for_prompt instructions =
  match trim_nonempty instructions with
  | None -> "[no keeper instructions]"
  | Some instructions -> instructions
;;

let goal_context_to_json = function
  | No_task -> `Assoc [ "status", `String "no_task" ]
  | Task_goals { task_id; criteria } ->
    let fields =
      match criteria with
      | Error detail -> [ "status", `String "unavailable"; "detail", `String detail ]
      | Ok goals ->
        [ "status", `String "available"
        ; ( "goals"
          , `List
              (List.map
                 (fun (goal_id, phase, criterion) ->
                    `Assoc
                      [ "goal_id", `String goal_id
                      ; "phase", Goal_phase.to_yojson phase
                      ; "criterion", Goal_store.criterion_to_yojson criterion
                      ])
                 goals) )
        ]
    in
    `Assoc (("task_id", `String task_id) :: fields)
;;

let keeper_id_variable (inp : input) =
  "keeper_id", Keeper_identity.Keeper_id.to_string inp.keeper_id
;;

let working_context_prompt_variables (inp : input) =
  [ keeper_id_variable inp
  ; "keeper_instructions", format_keeper_instructions_for_prompt inp.keeper_instructions
  ; "goal_context", Yojson.Safe.to_string (goal_context_to_json inp.goal_context)
  ; ( "working_context"
    , Yojson.Safe.to_string (Keeper_librarian_context.prompt_json inp.working_context) )
  ]
;;

let field_allowed ~allowed field = List.exists (String.equal field) allowed

let first_object_field_error ~allowed fields =
  let rec loop seen = function
    | [] -> None
    | (field, _) :: rest ->
      if String_set.mem field seen
      then Some (Duplicate_object_field field)
      else if not (field_allowed ~allowed field)
      then Some (Unexpected_object_field field)
      else loop (String_set.add field seen) rest
  in
  loop String_set.empty fields
;;

type parse_error =
  | Top_level_not_object
  | Working_context_invalid of string
  | Unexpected_field of string
  | Duplicate_field of string
  | Missing_required_fields

let parse_error_to_string = function
  | Top_level_not_object -> "top_level_not_object"
  | Working_context_invalid detail -> "working_context_invalid: " ^ detail
  | Unexpected_field field -> Printf.sprintf "unexpected_field:%s" field
  | Duplicate_field field -> Printf.sprintf "duplicate_field:%s" field
  | Missing_required_fields -> "missing_required_fields"
;;

let working_contexts_of_json (inp : input) json =
  Keeper_librarian_context.select inp.working_context json
  |> Result.map_error (fun detail -> Working_context_invalid detail)
;;

let single_field_of_json_result ~field json =
  match json with
  | `Assoc fields ->
    (match first_object_field_error ~allowed:[ field ] fields with
     | Some (Unexpected_object_field name) -> Error (Unexpected_field name)
     | Some (Duplicate_object_field name) -> Error (Duplicate_field name)
     | None ->
       (match List.assoc_opt field fields with
        | None -> Error Missing_required_fields
        | Some value -> Ok value))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error Top_level_not_object
;;

let working_contexts_of_json_result (inp : input) json =
  Result.bind
    (single_field_of_json_result ~field:wire_field_working_contexts json)
    (working_contexts_of_json inp)
;;
