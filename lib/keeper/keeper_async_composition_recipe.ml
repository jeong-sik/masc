module Plan = Keeper_tool_plan
module Plan_request = Keeper_tool_plan_request
module Tool_contract = Agent_core.Tool_contract
module Schedule = Agent_core.Execution_tool_schedule

module Assembler_run_id = struct
  type t = string

  type error = Empty

  let of_string = function
    | "" -> Error Empty
    | value -> Ok value
  ;;

  let to_string value = value
  let equal = String.equal
end

module Proposal_id = struct
  type t = string

  type error = Not_lowercase_sha256

  let of_string value =
    if String_util.is_lowercase_sha256_hex value
    then Ok value
    else Error Not_lowercase_sha256
  ;;

  let to_string value = value
  let equal = String.equal
end

type origin =
  | Skill_composition of Skill_reference.t
  | Assembler_proposal of
      { assembler_run_id : Assembler_run_id.t
      ; proposal_id : Proposal_id.t
      }

module Accepted_surface_digest = struct
  type t = string

  type error = Not_lowercase_sha256

  let of_string value =
    if String_util.is_lowercase_sha256_hex value
    then Ok value
    else Error Not_lowercase_sha256
  ;;

  let to_string value = value
  let equal = String.equal
end

type t =
  { composition_run_id : Plan.Composition_run_id.t
  ; origin : origin
  ; accepted_surface_digest : Accepted_surface_digest.t
  ; plan : Plan.t
  ; invocation : Tool_contract.Invocation.t
  ; accepted_checkpoint : Agent_core.Checkpoint.t
  }

type object_name =
  | Recipe
  | Origin
  | Invocation

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
  | Invalid_accepted_surface_digest of string
  | Negative_invocation_turn of int
  | Invalid_schedule of string
  | Invalid_completion of string
  | Invalid_completion_schedule of string
  | Invalid_plan of Plan_request.error
  | Invalid_checkpoint of Agent_core.Error.t

type create_error =
  | Unbound_plan of Plan_request.encode_error
  | Create_negative_invocation_turn of int
  | Create_invalid_invocation_schedule of string

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
        , `String (Assembler_run_id.to_string assembler_run_id) )
      ; "proposal_id", `String (Proposal_id.to_string proposal_id)
      ]
;;

let invocation_to_yojson invocation =
  `Assoc
    [ "tool_use_id", `String (Tool_contract.Invocation.tool_use_id invocation)
    ; "turn", `Int (Tool_contract.Invocation.turn invocation)
    ; "schedule", Schedule.to_yojson (Tool_contract.Invocation.schedule invocation)
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
  let* _ =
    Plan_request.to_yojson plan
    |> Result.map_error (fun error -> Unbound_plan error)
  in
  let turn = Tool_contract.Invocation.turn invocation in
  if turn < 0
  then Error (Create_negative_invocation_turn turn)
  else
    let schedule = Tool_contract.Invocation.schedule invocation in
    let completion = Tool_contract.Invocation.completion invocation in
    let* () =
      Schedule.validate_completion_message ~completion schedule
      |> Result.map_error (fun detail -> Create_invalid_invocation_schedule detail)
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

let to_yojson recipe =
  let* plan = Plan_request.to_yojson recipe.plan in
  Ok
    (`Assoc
      [ ( "composition_run_id"
        , `String (Plan.Composition_run_id.to_string recipe.composition_run_id) )
      ; "origin", origin_to_yojson recipe.origin
      ; ( "accepted_surface_digest"
        , `String (Accepted_surface_digest.to_string recipe.accepted_surface_digest) )
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
      Assembler_run_id.of_string assembler_run_id_value
      |> Result.map_error (fun Assembler_run_id.Empty -> Invalid_assembler_run_id)
    in
    let* proposal_id_value = required_string Origin "proposal_id" fields in
    let* proposal_id =
      Proposal_id.of_string proposal_id_value
      |> Result.map_error (fun Proposal_id.Not_lowercase_sha256 ->
        Invalid_proposal_id proposal_id_value)
    in
    Ok (Assembler_proposal { assembler_run_id; proposal_id })
  | value -> Error (Invalid_origin_kind value)
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
  if turn < 0
  then Error (Negative_invocation_turn turn)
  else
    let* schedule_json = required Invocation "schedule" fields in
    let* schedule =
      Schedule.of_yojson schedule_json
      |> Result.map_error (fun detail -> Invalid_schedule detail)
    in
    let* completion_json = required Invocation "completion" fields in
    let* completion =
      Tool_contract.completion_of_yojson completion_json
      |> Result.map_error (fun detail -> Invalid_completion detail)
    in
    let* () =
      Schedule.validate_completion_message ~completion schedule
      |> Result.map_error (fun detail -> Invalid_completion_schedule detail)
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
  let* accepted_surface_digest =
    Accepted_surface_digest.of_string accepted_surface_digest
    |> Result.map_error (fun Accepted_surface_digest.Not_lowercase_sha256 ->
      Invalid_accepted_surface_digest accepted_surface_digest)
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
