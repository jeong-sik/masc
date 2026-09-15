type failed_node =
  { node_id : string
  ; model_tool_name : string
  ; message : string
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
      ; failed_node : failed_node option
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
      ; message : string
      }
  | Recovery_proposal_rejected of
      { model_tool_name : string
      ; rejection : recovery_rejection
      ; message : string
      }
  | Agent_core_terminal_effect of { detail : string }

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
      ; failed_node = Some { node_id; model_tool_name; message }
      ; payload = _
      } ->
    Printf.sprintf
      "%s: %s (%s) failed: %s"
      composition_tool
      node_id
      model_tool_name
      (one_line message)
  | Composition_failed { composition_tool; failed_node = None; payload = _ } ->
    Printf.sprintf "%s failed" composition_tool
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
  | Boundary_observation_failed { model_tool_name; message } ->
    Printf.sprintf
      "%s tool boundary observation failed: %s"
      model_tool_name
      (one_line message)
  | Recovery_proposal_rejected { model_tool_name; rejection; message } ->
    Printf.sprintf
      "%s rejected the recovery proposal (%s): %s"
      model_tool_name
      (recovery_rejection_to_string rejection)
      (one_line message)
  | Agent_core_terminal_effect { detail } -> one_line detail
;;

let failed_node_to_yojson { node_id; model_tool_name; message } =
  `Assoc
    [ "node_id", `String node_id
    ; "model_tool_name", `String model_tool_name
    ; "message", `String message
    ]
;;

let to_yojson = function
  | Tool_failed { internal_tool_name; message } ->
    `Assoc
      [ "kind", `String "tool_failed"
      ; "internal_tool_name", `String internal_tool_name
      ; "message", `String message
      ]
  | Composition_failed { composition_tool; failed_node; payload } ->
    `Assoc
      [ "kind", `String "composition_failed"
      ; "composition_tool", `String composition_tool
      ; ( "failed_node"
        , match failed_node with
          | Some node -> failed_node_to_yojson node
          | None -> `Null )
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
  | Boundary_observation_failed { model_tool_name; message } ->
    `Assoc
      [ "kind", `String "boundary_observation_failed"
      ; "model_tool_name", `String model_tool_name
      ; "message", `String message
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

let failed_node_of_yojson json =
  let context = "failed_node" in
  let* fields =
    object_with_fields
      ~context
      ~expected:[ "node_id"; "model_tool_name"; "message" ]
      json
  in
  let* node_id = string_field ~context fields "node_id" in
  let* model_tool_name = string_field ~context fields "model_tool_name" in
  let* message = string_field ~context fields "message" in
  Ok { node_id; model_tool_name; message }
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
    let* fields = with_fields [ "composition_tool"; "failed_node"; "payload" ] in
    let* composition_tool = string_field ~context fields "composition_tool" in
    let* failed_node =
      let* node = field ~context fields "failed_node" in
      match node with
      | `Null -> Ok None
      | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `String _ ->
        Result.map Option.some (failed_node_of_yojson node)
    in
    let* payload = field ~context fields "payload" in
    Ok (Composition_failed { composition_tool; failed_node; payload })
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
    let* fields = with_fields [ "model_tool_name"; "message" ] in
    let* model_tool_name = string_field ~context fields "model_tool_name" in
    let* message = string_field ~context fields "message" in
    Ok (Boundary_observation_failed { model_tool_name; message })
  | "recovery_proposal_rejected" ->
    let* fields = with_fields [ "model_tool_name"; "rejection"; "message" ] in
    let* model_tool_name = string_field ~context fields "model_tool_name" in
    let* raw_rejection = string_field ~context fields "rejection" in
    let* rejection =
      match recovery_rejection_of_string raw_rejection with
      | Some rejection -> Ok rejection
      | None ->
        Error (Printf.sprintf "%s.rejection has unknown value %S" context raw_rejection)
    in
    let* message = string_field ~context fields "message" in
    Ok (Recovery_proposal_rejected { model_tool_name; rejection; message })
  | "agent_core_terminal_effect" ->
    let* fields = with_fields [ "detail" ] in
    let* detail = string_field ~context fields "detail" in
    Ok (Agent_core_terminal_effect { detail })
  | unknown -> Error (Printf.sprintf "terminal effect detail has unknown kind %S" unknown)
;;
