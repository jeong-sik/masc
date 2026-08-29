module Plan = Keeper_tool_plan
module Plan_request = Keeper_tool_plan_request
module Proposal = Keeper_plan_proposal
module Proposal_request = Keeper_plan_proposal_execution_request
module Tool_contract = Agent_core.Tool_contract

type origin =
  | Skill_composition of Skill_reference.t
  | Assembler_proposal of
      { assembler_run_id : Proposal_request.Assembler_run_id.t
      ; proposal_id : Proposal.Proposal_id.t
      }

type t =
  { composition_run_id : Plan.Composition_run_id.t
  ; origin : origin
  ; accepted_surface_digest : string
  ; plan : Plan.t
  ; invocation : Tool_contract.Invocation.t
  ; accepted_checkpoint : Agent_core.Checkpoint.t
  }

type object_name =
  | Recipe
  | Origin
  | Invocation
  | Schedule

type decode_error =
  | Expected_object of object_name
  | Duplicate_field of
      { object_name : object_name
      ; field : string
      }
  | Unknown_field of
      { object_name : object_name
      ; field : string
      }
  | Missing_field of
      { object_name : object_name
      ; field : string
      }
  | Expected_string of
      { object_name : object_name
      ; field : string
      }
  | Expected_int of
      { object_name : object_name
      ; field : string
      }
  | Invalid_composition_run_id of Plan.Composition_run_id.error
  | Invalid_origin_kind of string
  | Invalid_skill_reference of Skill_reference.decode_error
  | Invalid_assembler_run_id
  | Invalid_proposal_id of string
  | Invalid_execution_mode of string
  | Invalid_completion of string
  | Invalid_plan of Plan_request.error
  | Invalid_checkpoint of Agent_core.Error.t

let ( let* ) = Result.bind

let object_fields object_name = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Expected_object object_name)
;;

let reject_duplicates object_name fields =
  let rec inspect seen = function
    | [] -> Ok ()
    | (field, _) :: rest ->
      if List.mem field seen
      then Error (Duplicate_field { object_name; field })
      else inspect (field :: seen) rest
  in
  inspect [] fields
;;

let reject_unknown object_name ~allowed fields =
  match List.find_opt (fun (field, _) -> not (List.mem field allowed)) fields with
  | Some (field, _) -> Error (Unknown_field { object_name; field })
  | None -> Ok ()
;;

let exact_fields object_name ~allowed fields =
  let* () = reject_duplicates object_name fields in
  reject_unknown object_name ~allowed fields
;;

let required object_name field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Missing_field { object_name; field })
;;

let required_string object_name field fields =
  let* value = required object_name field fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Expected_string { object_name; field })
;;

let required_int object_name field fields =
  let* value = required object_name field fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Expected_int { object_name; field })
;;

let origin_to_yojson = function
  | Skill_composition reference ->
    `Assoc
      [ "kind", `String "skill_composition"
      ; "skill_reference", Skill_reference.to_yojson reference
      ]
  | Assembler_proposal { assembler_run_id; proposal_id } ->
    `Assoc
      [ "kind", `String "assembler_proposal"
      ; ( "assembler_run_id"
        , `String (Proposal_request.Assembler_run_id.to_string assembler_run_id) )
      ; "proposal_id", `String (Proposal.Proposal_id.to_string proposal_id)
      ]
;;

let schedule_to_yojson (schedule : Tool_contract.schedule) =
  `Assoc
    [ "planned_index", `Int schedule.planned_index
    ; "batch_index", `Int schedule.batch_index
    ; "batch_size", `Int schedule.batch_size
    ; "execution_mode", Tool_contract.execution_mode_to_yojson schedule.execution_mode
    ]
;;

let invocation_to_yojson invocation =
  `Assoc
    [ "tool_use_id", `String (Tool_contract.Invocation.tool_use_id invocation)
    ; "turn", `Int (Tool_contract.Invocation.turn invocation)
    ; "schedule", schedule_to_yojson (Tool_contract.Invocation.schedule invocation)
    ; "completion", Tool_contract.completion_to_yojson (Tool_contract.Invocation.completion invocation)
    ]
;;

let create
      ~composition_run_id
      ~origin
      ~accepted_surface_digest
      ~plan
      ~invocation
      ~accepted_checkpoint
  =
  let* _ = Plan_request.to_yojson plan in
  Ok
    { composition_run_id
    ; origin
    ; accepted_surface_digest
    ; plan
    ; invocation
    ; accepted_checkpoint
    }
;;

let to_yojson recipe =
  let* plan = Plan_request.to_yojson recipe.plan in
  Ok
    (`Assoc
      [ ( "composition_run_id"
        , `String (Plan.Composition_run_id.to_string recipe.composition_run_id) )
      ; "origin", origin_to_yojson recipe.origin
      ; "accepted_surface_digest", `String recipe.accepted_surface_digest
      ; "plan", plan
      ; "invocation", invocation_to_yojson recipe.invocation
      ; "accepted_checkpoint", Agent_core.Checkpoint.to_json recipe.accepted_checkpoint
      ])
;;

let origin_of_yojson json =
  let* fields = object_fields Origin json in
  let* () = reject_duplicates Origin fields in
  let* kind = required_string Origin "kind" fields in
  match kind with
  | "skill_composition" ->
    let* () =
      reject_unknown Origin ~allowed:[ "kind"; "skill_reference" ] fields
    in
    let* reference_json = required Origin "skill_reference" fields in
    let* reference =
      Skill_reference.of_yojson reference_json
      |> Result.map_error (fun error -> Invalid_skill_reference error)
    in
    Ok (Skill_composition reference)
  | "assembler_proposal" ->
    let* () =
      reject_unknown
        Origin
        ~allowed:[ "kind"; "assembler_run_id"; "proposal_id" ]
        fields
    in
    let* assembler_run_id_value = required_string Origin "assembler_run_id" fields in
    let* assembler_run_id =
      Proposal_request.Assembler_run_id.of_string assembler_run_id_value
      |> Result.map_error (fun _ -> Invalid_assembler_run_id)
    in
    let* proposal_id_value = required_string Origin "proposal_id" fields in
    let* proposal_id =
      Proposal.Proposal_id.of_string proposal_id_value
      |> Result.map_error (fun Proposal.Proposal_id.Not_lowercase_sha256 ->
        Invalid_proposal_id proposal_id_value)
    in
    Ok (Assembler_proposal { assembler_run_id; proposal_id })
  | value -> Error (Invalid_origin_kind value)
;;

let schedule_of_yojson json =
  let* fields = object_fields Schedule json in
  let* () =
    exact_fields
      Schedule
      ~allowed:[ "planned_index"; "batch_index"; "batch_size"; "execution_mode" ]
      fields
  in
  let* planned_index = required_int Schedule "planned_index" fields in
  let* batch_index = required_int Schedule "batch_index" fields in
  let* batch_size = required_int Schedule "batch_size" fields in
  let* execution_mode_json = required Schedule "execution_mode" fields in
  let* execution_mode =
    Tool_contract.execution_mode_of_yojson execution_mode_json
    |> Result.map_error (fun detail -> Invalid_execution_mode detail)
  in
  Ok { Tool_contract.planned_index; batch_index; batch_size; execution_mode }
;;

let invocation_of_yojson json =
  let* fields = object_fields Invocation json in
  let* () =
    exact_fields
      Invocation
      ~allowed:[ "tool_use_id"; "turn"; "schedule"; "completion" ]
      fields
  in
  let* tool_use_id = required_string Invocation "tool_use_id" fields in
  let* turn = required_int Invocation "turn" fields in
  let* schedule_json = required Invocation "schedule" fields in
  let* schedule = schedule_of_yojson schedule_json in
  let* completion_json = required Invocation "completion" fields in
  let* completion =
    Tool_contract.completion_of_yojson completion_json
    |> Result.map_error (fun detail -> Invalid_completion detail)
  in
  Ok (Tool_contract.Invocation.create ~tool_use_id ~turn ~schedule ~completion)
;;

let of_yojson ~descriptors json =
  let* fields = object_fields Recipe json in
  let* () =
    exact_fields
      Recipe
      ~allowed:
        [ "composition_run_id"
        ; "origin"
        ; "accepted_surface_digest"
        ; "plan"
        ; "invocation"
        ; "accepted_checkpoint"
        ]
      fields
  in
  let* composition_run_id_value = required_string Recipe "composition_run_id" fields in
  let* composition_run_id =
    Plan.Composition_run_id.of_string composition_run_id_value
    |> Result.map_error (fun error -> Invalid_composition_run_id error)
  in
  let* origin_json = required Recipe "origin" fields in
  let* origin = origin_of_yojson origin_json in
  let* accepted_surface_digest =
    required_string Recipe "accepted_surface_digest" fields
  in
  let* plan_json = required Recipe "plan" fields in
  let* plan =
    Plan_request.plan_of_json ~descriptors plan_json
    |> Result.map_error (fun error -> Invalid_plan error)
  in
  let* invocation_json = required Recipe "invocation" fields in
  let* invocation = invocation_of_yojson invocation_json in
  let* checkpoint_json = required Recipe "accepted_checkpoint" fields in
  let* accepted_checkpoint =
    Agent_core.Checkpoint.of_json checkpoint_json
    |> Result.map_error (fun error -> Invalid_checkpoint error)
  in
  Ok
    { composition_run_id
    ; origin
    ; accepted_surface_digest
    ; plan
    ; invocation
    ; accepted_checkpoint
    }
;;

let composition_run_id recipe = recipe.composition_run_id
let origin recipe = recipe.origin
let accepted_surface_digest recipe = recipe.accepted_surface_digest
let plan recipe = recipe.plan
let invocation recipe = recipe.invocation
let accepted_checkpoint recipe = recipe.accepted_checkpoint
