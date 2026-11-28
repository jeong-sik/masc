(* The AG-UI frames the server builds: one case per Ag_ui constructor and
   option combination a call site passes. The wire conformance test and the
   fixture emitter read this one list, so a fixture never misses a case the
   test checks. *)

let timestamp = 1795821563.25
let thread = "keeper:imp"
let run = "keeper-operation-run-op-1"
let occurrence_id = "toolu_01"

let occurrence : Ag_ui.tool_stream_occurrence =
  { stream_scope = 3; provider_message_id = Some "msg_01"; block_index = 1 }

let bare_occurrence : Ag_ui.tool_stream_occurrence =
  { occurrence with provider_message_id = None }

(* Every option combination the server's call sites pass to each
   constructor. The PR body lists the call sites. *)
let cases : (string * Ag_ui.event) list =
  let open Ag_ui in
  [ ( "run_started",
      run_started ~timestamp ~thread_id:thread ~run_id:run () )
  ; ( "run_started on the default thread (/ag-ui/events prime)",
      run_started ~timestamp ~thread_id:default_thread_id ~run_id:"session-1" () )
  ; ( "run_finished",
      run_finished ~timestamp ~thread_id:thread ~run_id:run () )
  ; ( "run_finished at a whole-second timestamp",
      run_finished ~timestamp:13.0 ~thread_id:thread ~run_id:run () )
  ; ( "run_error with run_id and code",
      run_error ~timestamp ~thread_id:thread ~run_id:run ~message:"stream cut"
        ~code:"event_error" () )
  ; ( "run_error without run_id or code",
      run_error ~timestamp ~thread_id:thread ~message:"provider refused" () )
  ; ( "text_message_start",
      text_message_start ~timestamp ~thread_id:thread ~run_id:run ~message_id:"m-1"
        ~role:Assistant () )
  ; ( "text_message_content, response observed",
      text_message_content ~timestamp ~thread_id:thread ~run_id:run ~message_id:"m-1"
        ~text_response:(Observed_response { response_generation = 2; response_scope = 7 })
        ~delta:"Hello" () )
  ; ( "text_message_content, scope only",
      text_message_content ~timestamp ~thread_id:thread ~run_id:run ~message_id:"m-1"
        ~text_response:(Unobserved_scope (Some 7)) ~delta:"Hello" () )
  ; ( "text_message_content, no run, message_id or scope",
      text_message_content ~timestamp ~thread_id:thread ~delta:"" () )
  ; ( "text_message_end",
      text_message_end ~timestamp ~thread_id:thread ~run_id:run ~message_id:"m-1" () )
  ; ( "text_message_end without message_id",
      text_message_end ~timestamp ~thread_id:thread ~run_id:run () )
  ; ( "tool_call_start",
      tool_call_start ~timestamp ~thread_id:thread ~run_id:run ~tool_call_id:occurrence_id
        ~tool_call_name:"shell" occurrence )
  ; ( "tool_call_start without tool_call_id or provider_message_id",
      tool_call_start ~timestamp ~thread_id:thread ~run_id:run ~tool_call_name:"shell"
        bare_occurrence )
  ; ( "tool_call_args delta",
      tool_call_args ~timestamp ~thread_id:thread ~run_id:run ~tool_call_id:occurrence_id
        occurrence (Arguments_delta "{\"cmd\":") )
  ; ( "tool_call_args snapshot",
      tool_call_args ~timestamp ~thread_id:thread ~run_id:run ~tool_call_id:occurrence_id
        occurrence (Arguments_snapshot "{\"cmd\":\"ls\"}") )
  ; ( "tool_call_end",
      tool_call_end ~timestamp ~thread_id:thread ~run_id:run ~tool_call_id:occurrence_id
        occurrence )
  ; ( "custom with run_id and null value",
      custom ~timestamp ~thread_id:thread ~run_id:run ~name:"KEEPER_CONNECTED" `Null )
  ; ( "custom before RUN_STARTED (no run_id)",
      custom ~timestamp ~thread_id:default_thread_id ~name:"KEEPER_ATTACHMENT"
        (`Assoc [ "attachment_id", `String "att_1"; "role", `String "assistant" ]) )
  ; ( "of_custom accepted",
      of_custom ~timestamp ~name:"KEEPER_CHAT_OPERATION_ACCEPTED"
        (`Assoc [ "operation_id", `String "op-1"; "state", `String "queued"; "queued_count", `Int 0 ]) )
  ; ( "of_custom MASC_EVENT",
      of_custom ~timestamp ~name:"MASC_EVENT" (`Assoc [ "type", `String "task_updated" ]) )
  ]

(* JSON values with object keys compared as a set. *)
let rec normalize : Yojson.Safe.t -> Yojson.Safe.t = function
  | `Assoc fields ->
    `Assoc
      (List.sort (fun (a, _) (b, _) -> String.compare a b)
         (List.map (fun (key, value) -> key, normalize value) fields))
  | `List items -> `List (List.map normalize items)
  | other -> other
