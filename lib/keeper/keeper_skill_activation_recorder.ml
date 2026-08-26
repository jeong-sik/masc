open Result.Syntax

module Ledger = Keeper_skill_activation_ledger

type t =
  { trace_id : Keeper_id.Trace_id.t
  ; turn_ref : Ids.Turn_ref.t
  ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; task_id : Keeper_id.Task_id.t option
  ; task_references : Skill_reference.t list
  }

type error =
  | Turn_scope_mismatch
  | Task_scope_missing of Skill_reference.t
  | Composition_reference_missing of { tool_name : string }
  | Activation_rejected of Ledger.decode_error
  | Store_failed of Ledger.store_error

let make ~trace_id ~turn_ref ~snapshot_revision ~task_id ~task_references =
  if
    String.equal
      (Keeper_id.Trace_id.to_string trace_id)
      (Ids.Turn_ref.trace_id turn_ref)
  then
    Ok { trace_id; turn_ref; snapshot_revision; task_id; task_references }
  else Error Turn_scope_mismatch
;;

let declared_by_task context reference =
  List.exists (Skill_reference.equal reference) context.task_references
;;

let instruction_origin context reference =
  match declared_by_task context reference, context.task_id with
  | true, Some task_id -> Ok (Ledger.Task_instruction { task_id })
  | true, None -> Error (Task_scope_missing reference)
  | false, Some _ | false, None -> Ok Ledger.Session_instruction
;;

let composition_origin context ~tool_name reference =
  match declared_by_task context reference, context.task_id with
  | true, Some task_id -> Ok (Ledger.Task_composition { task_id; tool_name })
  | true, None -> Error (Task_scope_missing reference)
  | false, Some _ | false, None -> Ok (Ledger.Session_composition { tool_name })
;;

let record ~config context ~origin reference =
  let* activation =
    Ledger.make_activation
      ~identity:reference.Skill_reference.identity
      ~content_revision:reference.content_revision
      ~snapshot_revision:context.snapshot_revision
      ~turn_ref:context.turn_ref
      ~activated_at:(Masc_domain.now_iso ())
      ~origin
    |> Result.map_error (fun error -> Activation_rejected error)
  in
  Ledger.record ~config ~trace_id:context.trace_id activation
  |> Result.map snd
  |> Result.map_error (fun error -> Store_failed error)
;;

let record_instruction ~config context reference =
  let* origin = instruction_origin context reference in
  record ~config context ~origin reference
;;

let record_composition ~config context ~tool_name reference =
  let* origin = composition_origin context ~tool_name reference in
  record ~config context ~origin reference
;;

let error_code = function
  | Turn_scope_mismatch -> "turn_scope_mismatch"
  | Task_scope_missing _ -> "task_scope_missing"
  | Composition_reference_missing _ -> "composition_reference_missing"
  | Activation_rejected _ -> "activation_rejected"
  | Store_failed _ -> "store_failed"
;;

let error_to_string = function
  | Turn_scope_mismatch ->
    "Skill activation turn reference does not belong to the Keeper trace"
  | Task_scope_missing reference ->
    Printf.sprintf
      "Task-declared Skill activation has no typed current Task: %s"
      (Skill_reference.to_yojson reference |> Yojson.Safe.to_string)
  | Composition_reference_missing { tool_name } ->
    Printf.sprintf "Skill composition %s has no exact catalog reference" tool_name
  | Activation_rejected _ -> "Skill activation was rejected by the typed ledger"
  | Store_failed error ->
    "Skill activation ledger write failed: " ^ Ledger.store_error_to_string error
;;

let error_to_yojson error =
  `Assoc
    [ "code", `String (error_code error)
    ; "detail", `String (error_to_string error)
    ]
;;
