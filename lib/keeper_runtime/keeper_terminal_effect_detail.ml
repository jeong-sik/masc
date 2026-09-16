type failed_node =
  { node_id : string
  ; model_tool_name : string
  ; message : string
  }

type plan_execution_error =
  | Unknown_node_id
  | Input_template_resolution_failed
  | Input_validation_failed
  | Output_validation_failed
  | Output_not_composable

type node_deferral =
  | Deferral_unrecorded
  | Generic_deferral
  | External_effect_deferral

type composition_cause =
  | Node_failed of failed_node
  | Node_deferred of
      { node_id : string
      ; model_tool_name : string
      ; deferral : node_deferral
      }
  | Node_observation_failed of
      { node_id : string
      ; model_tool_name : string
      ; detail : string
      }
  | Plan_execution_failed of
      { node_id : string
      ; error : plan_execution_error
      }

type recovery_rejection =
  | Recovery_store_failed
  | Recovery_source_unavailable
  | Recovery_submission_invalid
  | Recovery_projection_rejected

type t =
  | Tool_failed of
      { internal_tool_name : string
      ; message : string
      }
  | Composition_failed of
      { composition_tool : string
      ; cause : composition_cause
      ; payload : Yojson.Safe.t
      }
  | Composition_result_manifest_unpersisted of
      { composition_tool : string
      ; detail : string
      }
  | Composition_evidence_unpublished of
      { composition_tool : string
      ; detail : string
      }
  | Terminal_tool_receipt_missing of { internal_tool_name : string }
  | Terminal_composition_receipt_missing of { composition_tool : string }
  | Output_artifact_unstored of { message : string }
  | Output_over_inline_budget of { message : string }
  | Result_delivery_failed of
      { model_tool_name : string
      ; message : string
      }
  | Boundary_observation_failed of
      { model_tool_name : string
      ; cause : Keeper_request_failure_core.t
      }
  | Recovery_proposal_rejected of
      { model_tool_name : string
      ; rejection : recovery_rejection
      ; message : string
      }
  | Agent_core_terminal_effect of { detail : string }

let plan_execution_error_to_string = function
  | Unknown_node_id -> "unknown_node_id"
  | Input_template_resolution_failed -> "input_template_resolution_failed"
  | Input_validation_failed -> "input_validation_failed"
  | Output_validation_failed -> "output_validation_failed"
  | Output_not_composable -> "output_not_composable"
;;

let plan_execution_error_of_string = function
  | "unknown_node_id" -> Some Unknown_node_id
  | "input_template_resolution_failed" -> Some Input_template_resolution_failed
  | "input_validation_failed" -> Some Input_validation_failed
  | "output_validation_failed" -> Some Output_validation_failed
  | "output_not_composable" -> Some Output_not_composable
  | _ -> None
;;

let node_deferral_to_string = function
  | Deferral_unrecorded -> "unrecorded"
  | Generic_deferral -> "generic"
  | External_effect_deferral -> "external_effect"
;;

let node_deferral_of_string = function
  | "unrecorded" -> Some Deferral_unrecorded
  | "generic" -> Some Generic_deferral
  | "external_effect" -> Some External_effect_deferral
  | _ -> None
;;

let recovery_rejection_to_string = function
  | Recovery_store_failed -> "store_failed"
  | Recovery_source_unavailable -> "source_unavailable"
  | Recovery_submission_invalid -> "submission_invalid"
  | Recovery_projection_rejected -> "projection_rejected"
;;

let recovery_rejection_of_string = function
  | "store_failed" -> Some Recovery_store_failed
  | "source_unavailable" -> Some Recovery_source_unavailable
  | "submission_invalid" -> Some Recovery_submission_invalid
  | "projection_rejected" -> Some Recovery_projection_rejected
  | _ -> None
;;

(* A leaf message is the producer's own text and may span lines; the summary
   is one line. *)
let one_line text = String.map (function '\n' | '\r' -> ' ' | c -> c) text

let summary = function
  | Tool_failed { internal_tool_name; message } ->
    Printf.sprintf "%s failed: %s" internal_tool_name (one_line message)
  | Composition_failed
      { composition_tool
      ; cause = Node_failed { node_id; model_tool_name; message }
      ; payload = _
      } ->
    Printf.sprintf
      "%s: %s (%s) failed: %s"
      composition_tool
      node_id
      model_tool_name
      (one_line message)
  | Composition_failed
      { composition_tool
      ; cause = Node_deferred { node_id; model_tool_name; deferral }
      ; payload = _
      } ->
    Printf.sprintf
      "%s: %s (%s) deferred (%s), so the plan stopped there"
      composition_tool
      node_id
      model_tool_name
      (node_deferral_to_string deferral)
  | Composition_failed
      { composition_tool
      ; cause = Node_observation_failed { node_id; model_tool_name; detail }
      ; payload = _
      } ->
    Printf.sprintf
      "%s: %s (%s) completed but its result was not recorded: %s"
      composition_tool
      node_id
      model_tool_name
      (one_line detail)
  | Composition_failed
      { composition_tool; cause = Plan_execution_failed { node_id; error }; payload = _ }
    ->
    Printf.sprintf
      "%s: plan stopped at %s: %s"
      composition_tool
      node_id
      (plan_execution_error_to_string error)
  | Composition_result_manifest_unpersisted { composition_tool; detail } ->
    Printf.sprintf
      "%s: result manifest was not persisted: %s"
      composition_tool
      (one_line detail)
  | Composition_evidence_unpublished { composition_tool; detail } ->
    Printf.sprintf
      "%s: recovery evidence was not published: %s"
      composition_tool
      (one_line detail)
  | Terminal_tool_receipt_missing { internal_tool_name } ->
    Printf.sprintf "%s completed without a typed effect receipt" internal_tool_name
  | Terminal_composition_receipt_missing { composition_tool } ->
    Printf.sprintf "%s completed without a typed target receipt" composition_tool
  | Output_artifact_unstored { message } ->
    Printf.sprintf "tool output artifact storage failed: %s" (one_line message)
  | Output_over_inline_budget { message } ->
    Printf.sprintf "tool output exceeded its inline budget: %s" (one_line message)
  | Result_delivery_failed { model_tool_name; message } ->
    Printf.sprintf "%s result was not delivered: %s" model_tool_name (one_line message)
  | Boundary_observation_failed { model_tool_name; cause } ->
    Printf.sprintf
      "%s tool boundary observation failed: %s"
      model_tool_name
      (Keeper_request_failure_core.summary cause)
  | Recovery_proposal_rejected { model_tool_name; rejection; message } ->
    Printf.sprintf
      "%s rejected the recovery proposal (%s): %s"
      model_tool_name
      (recovery_rejection_to_string rejection)
      (one_line message)
  | Agent_core_terminal_effect { detail } -> one_line detail
;;

let composition_cause_to_yojson = function
  | Node_failed { node_id; model_tool_name; message } ->
    `Assoc
      [ "kind", `String "node_failed"
      ; "node_id", `String node_id
      ; "model_tool_name", `String model_tool_name
      ; "message", `String message
      ]
  | Node_deferred { node_id; model_tool_name; deferral } ->
    `Assoc
      [ "kind", `String "node_deferred"
      ; "node_id", `String node_id
      ; "model_tool_name", `String model_tool_name
      ; "deferral", `String (node_deferral_to_string deferral)
      ]
  | Node_observation_failed { node_id; model_tool_name; detail } ->
    `Assoc
      [ "kind", `String "node_observation_failed"
      ; "node_id", `String node_id
      ; "model_tool_name", `String model_tool_name
      ; "detail", `String detail
      ]
  | Plan_execution_failed { node_id; error } ->
    `Assoc
      [ "kind", `String "plan_execution_failed"
      ; "node_id", `String node_id
      ; "error", `String (plan_execution_error_to_string error)
      ]
;;

let to_yojson = function
  | Tool_failed { internal_tool_name; message } ->
    `Assoc
      [ "kind", `String "tool_failed"
      ; "internal_tool_name", `String internal_tool_name
      ; "message", `String message
      ]
  | Composition_failed { composition_tool; cause; payload } ->
    `Assoc
      [ "kind", `String "composition_failed"
      ; "composition_tool", `String composition_tool
      ; "cause", composition_cause_to_yojson cause
      ; "payload", payload
      ]
  | Composition_result_manifest_unpersisted { composition_tool; detail } ->
    `Assoc
      [ "kind", `String "composition_result_manifest_unpersisted"
      ; "composition_tool", `String composition_tool
      ; "detail", `String detail
      ]
  | Composition_evidence_unpublished { composition_tool; detail } ->
    `Assoc
      [ "kind", `String "composition_evidence_unpublished"
      ; "composition_tool", `String composition_tool
      ; "detail", `String detail
      ]
  | Terminal_tool_receipt_missing { internal_tool_name } ->
    `Assoc
      [ "kind", `String "terminal_tool_receipt_missing"
      ; "internal_tool_name", `String internal_tool_name
      ]
  | Terminal_composition_receipt_missing { composition_tool } ->
    `Assoc
      [ "kind", `String "terminal_composition_receipt_missing"
      ; "composition_tool", `String composition_tool
      ]
  | Output_artifact_unstored { message } ->
    `Assoc [ "kind", `String "output_artifact_unstored"; "message", `String message ]
  | Output_over_inline_budget { message } ->
    `Assoc [ "kind", `String "output_over_inline_budget"; "message", `String message ]
  | Result_delivery_failed { model_tool_name; message } ->
    `Assoc
      [ "kind", `String "result_delivery_failed"
      ; "model_tool_name", `String model_tool_name
      ; "message", `String message
      ]
  | Boundary_observation_failed { model_tool_name; cause } ->
    `Assoc
      [ "kind", `String "boundary_observation_failed"
      ; "model_tool_name", `String model_tool_name
      ; "cause", Keeper_request_failure_core.to_yojson cause
      ]
  | Recovery_proposal_rejected { model_tool_name; rejection; message } ->
    `Assoc
      [ "kind", `String "recovery_proposal_rejected"
      ; "model_tool_name", `String model_tool_name
      ; "rejection", `String (recovery_rejection_to_string rejection)
      ; "message", `String message
      ]
  | Agent_core_terminal_effect { detail } ->
    `Assoc [ "kind", `String "agent_core_terminal_effect"; "detail", `String detail ]
;;

let ( let* ) = Result.bind

(* Every object this module writes has a closed field set. A field this
   decoder does not know is refused, the same as a missing one. *)
let object_with_fields ~context ~expected = function
  | `Assoc fields ->
    let actual = List.sort String.compare (List.map fst fields) in
    let expected = List.sort String.compare expected in
    if List.equal String.equal actual expected
    then Ok fields
    else
      Error
        (Printf.sprintf
           "%s fields must be exactly [%s], got [%s]"
           context
           (String.concat "," expected)
           (String.concat "," actual))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error (context ^ " is not an object")
;;

let field ~context fields name =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s has no %s" context name)
;;

let string_field ~context fields name =
  let* value = field ~context fields name in
  match value with
  | `String text -> Ok text
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null ->
    Error (Printf.sprintf "%s.%s is not a string" context name)
;;

let enum_field ~context fields name of_string =
  let* raw = string_field ~context fields name in
  match of_string raw with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s.%s has unknown value %S" context name raw)
;;

let core_failure_field ~context fields name =
  let* value = field ~context fields name in
  Keeper_request_failure_core.of_yojson value
  |> Result.map_error (fun error -> Printf.sprintf "%s.%s: %s" context name error)
;;

let composition_cause_of_yojson json =
  let* kind =
    match json with
    | `Assoc fields -> string_field ~context:"composition cause" fields "kind"
    | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      Error "composition cause is not an object"
  in
  let context = "composition cause " ^ kind in
  let with_fields expected =
    object_with_fields ~context ~expected:("kind" :: expected) json
  in
  match kind with
  | "node_failed" ->
    let* fields = with_fields [ "node_id"; "model_tool_name"; "message" ] in
    let* node_id = string_field ~context fields "node_id" in
    let* model_tool_name = string_field ~context fields "model_tool_name" in
    let* message = string_field ~context fields "message" in
    Ok (Node_failed { node_id; model_tool_name; message })
  | "node_deferred" ->
    let* fields = with_fields [ "node_id"; "model_tool_name"; "deferral" ] in
    let* node_id = string_field ~context fields "node_id" in
    let* model_tool_name = string_field ~context fields "model_tool_name" in
    let* deferral = enum_field ~context fields "deferral" node_deferral_of_string in
    Ok (Node_deferred { node_id; model_tool_name; deferral })
  | "node_observation_failed" ->
    let* fields = with_fields [ "node_id"; "model_tool_name"; "detail" ] in
    let* node_id = string_field ~context fields "node_id" in
    let* model_tool_name = string_field ~context fields "model_tool_name" in
    let* detail = string_field ~context fields "detail" in
    Ok (Node_observation_failed { node_id; model_tool_name; detail })
  | "plan_execution_failed" ->
    let* fields = with_fields [ "node_id"; "error" ] in
    let* node_id = string_field ~context fields "node_id" in
    let* error = enum_field ~context fields "error" plan_execution_error_of_string in
    Ok (Plan_execution_failed { node_id; error })
  | unknown -> Error (Printf.sprintf "composition cause has unknown kind %S" unknown)
;;

let of_yojson json =
  let* kind =
    match json with
    | `Assoc fields -> string_field ~context:"terminal effect detail" fields "kind"
    | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      Error "terminal effect detail is not an object"
  in
  let context = "terminal effect detail " ^ kind in
  let with_fields expected =
    object_with_fields ~context ~expected:("kind" :: expected) json
  in
  match kind with
  | "tool_failed" ->
    let* fields = with_fields [ "internal_tool_name"; "message" ] in
    let* internal_tool_name = string_field ~context fields "internal_tool_name" in
    let* message = string_field ~context fields "message" in
    Ok (Tool_failed { internal_tool_name; message })
  | "composition_failed" ->
    let* fields = with_fields [ "composition_tool"; "cause"; "payload" ] in
    let* composition_tool = string_field ~context fields "composition_tool" in
    let* cause = field ~context fields "cause" in
    let* cause = composition_cause_of_yojson cause in
    let* payload = field ~context fields "payload" in
    Ok (Composition_failed { composition_tool; cause; payload })
  | "composition_result_manifest_unpersisted" ->
    let* fields = with_fields [ "composition_tool"; "detail" ] in
    let* composition_tool = string_field ~context fields "composition_tool" in
    let* detail = string_field ~context fields "detail" in
    Ok (Composition_result_manifest_unpersisted { composition_tool; detail })
  | "composition_evidence_unpublished" ->
    let* fields = with_fields [ "composition_tool"; "detail" ] in
    let* composition_tool = string_field ~context fields "composition_tool" in
    let* detail = string_field ~context fields "detail" in
    Ok (Composition_evidence_unpublished { composition_tool; detail })
  | "terminal_tool_receipt_missing" ->
    let* fields = with_fields [ "internal_tool_name" ] in
    let* internal_tool_name = string_field ~context fields "internal_tool_name" in
    Ok (Terminal_tool_receipt_missing { internal_tool_name })
  | "terminal_composition_receipt_missing" ->
    let* fields = with_fields [ "composition_tool" ] in
    let* composition_tool = string_field ~context fields "composition_tool" in
    Ok (Terminal_composition_receipt_missing { composition_tool })
  | "output_artifact_unstored" ->
    let* fields = with_fields [ "message" ] in
    let* message = string_field ~context fields "message" in
    Ok (Output_artifact_unstored { message })
  | "output_over_inline_budget" ->
    let* fields = with_fields [ "message" ] in
    let* message = string_field ~context fields "message" in
    Ok (Output_over_inline_budget { message })
  | "result_delivery_failed" ->
    let* fields = with_fields [ "model_tool_name"; "message" ] in
    let* model_tool_name = string_field ~context fields "model_tool_name" in
    let* message = string_field ~context fields "message" in
    Ok (Result_delivery_failed { model_tool_name; message })
  | "boundary_observation_failed" ->
    let* fields = with_fields [ "model_tool_name"; "cause" ] in
    let* model_tool_name = string_field ~context fields "model_tool_name" in
    let* cause = core_failure_field ~context fields "cause" in
    Ok (Boundary_observation_failed { model_tool_name; cause })
  | "recovery_proposal_rejected" ->
    let* fields = with_fields [ "model_tool_name"; "rejection"; "message" ] in
    let* model_tool_name = string_field ~context fields "model_tool_name" in
    let* rejection =
      enum_field ~context fields "rejection" recovery_rejection_of_string
    in
    let* message = string_field ~context fields "message" in
    Ok (Recovery_proposal_rejected { model_tool_name; rejection; message })
  | "agent_core_terminal_effect" ->
    let* fields = with_fields [ "detail" ] in
    let* detail = string_field ~context fields "detail" in
    Ok (Agent_core_terminal_effect { detail })
  | unknown -> Error (Printf.sprintf "terminal effect detail has unknown kind %S" unknown)
;;
