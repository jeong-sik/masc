(* The agent_failed payload is encoded by the atd-generated writer. The
   baseline spells the field order out by hand, so an atd change that renames
   or reorders a field fails here. *)

let baseline_agent_failed ~agent_name ~task_id ~elapsed_s ~error_fields =
  `Assoc
    ([ "agent_name", `String agent_name
     ; "task_id", `String task_id
     ; "elapsed_s", `Float elapsed_s
     ]
     @ error_fields)
;;

let agent_failed_error : string =
  "HookExecutionFailed { hook_name = post_tool_use }"

let agent_failed_error_domain : string = "agent"
let agent_failed_error_code : string = "hook_execution_failed"
let agent_failed_error_retryable : bool = false

let agent_failed_error_detail : Yojson.Safe.t =
  `Assoc
    [ "variant", `String "hook_execution_failed"
    ; "hook_name", `String "post_tool_use"
    ; "stage", `String "execute"
    ]
;;

let agent_failed_error_fields_sample : (string * Yojson.Safe.t) list =
  [ "error", `String agent_failed_error
  ; "error_domain", `String agent_failed_error_domain
  ; "error_code", `String agent_failed_error_code
  ; "error_retryable", `Bool agent_failed_error_retryable
  ; "error_detail", agent_failed_error_detail
  ]
;;

let test_agent_failed_payload_byte_equal () =
  let baseline =
    Yojson.Safe.to_string
      (baseline_agent_failed
         ~agent_name:"alpha"
         ~task_id:"task_42"
         ~elapsed_s:3.5
         ~error_fields:agent_failed_error_fields_sample)
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.agent_failed_payload
         ~agent_name:"alpha"
         ~task_id:"task_42"
         ~elapsed_s:3.5
         ~error:agent_failed_error
         ~error_domain:agent_failed_error_domain
         ~error_code:agent_failed_error_code
         ~error_retryable:agent_failed_error_retryable
         ~error_detail:agent_failed_error_detail)
  in
  Alcotest.(check string) "agent_failed typed == baseline" baseline typed
;;

let () =
  Alcotest.run
    "sse_event"
    [ ( "agent_failed"
      , [ Alcotest.test_case "payload field order" `Quick
            test_agent_failed_payload_byte_equal
        ] )
    ]
;;
