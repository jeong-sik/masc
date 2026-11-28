(* The AG-UI frames the server writes today decode into the keeper_chat_wire
   types, and writing the decoded value back gives the same JSON value.

   Each case builds an event with the field set of one construction site
   (file:line in the case name), encodes it with the server's encoder
   (Ag_ui.event_to_json), and reads it with the atd-generated reader. The
   comparison is on JSON values: object key order is not part of the wire. *)

module Wire_j = Keeper_chat_wire.Keeper_chat_wire_j
module Wire_t = Keeper_chat_wire.Keeper_chat_wire_t

let timestamp = 1795821563.25
let thread = "keeper:imp"
let run = "keeper-operation-run-op-1"
let occurrence_id = "toolu_01"

(* The occurrence fields every TOOL_CALL_* site sets (projection.ml:351-387). *)
let tool_event ?(tool_call_id = Some occurrence_id) ?(provider_message_id = Some "msg_01")
    ?tool_call_name ?delta ?snapshot event_type =
  Ag_ui.make_event ~timestamp ~thread_id:thread ~run_id:(Some run) ~tool_call_id
    ~tool_stream_scope:(Some 3) ~provider_message_id ~tool_call_block_index:(Some 1)
    ?tool_call_name ?delta ?snapshot event_type

let cases : (string * Ag_ui.event) list =
  let open Ag_ui in
  [ ( "ag_ui.ml:132 run_error with code",
      run_error ~thread_id:thread ~run_id:run ~message:"provider refused" ~code:"event_error" () )
  ; ( "ag_ui.ml:132 run_error without run_id or code",
      run_error ~thread_id:thread ~message:"provider refused" () )
  ; ( "ag_ui.ml:180 of_custom accepted",
      of_custom ~timestamp ~name:"KEEPER_CHAT_OPERATION_ACCEPTED"
        (`Assoc [ "operation_id", `String "op-1"; "state", `String "queued"; "queued_count", `Int 0 ]) )
  ; ( "projection.ml:84 custom with run_id and null value",
      make_event ~timestamp ~thread_id:thread ~run_id:(Some run)
        ~custom_name:(Some "KEEPER_CONNECTED") ~custom_value:(Some `Null) Custom )
  ; ( "projection.ml:84 custom before RUN_STARTED (no run_id)",
      make_event ~timestamp ~thread_id:default_thread_id
        ~custom_name:(Some "KEEPER_ATTACHMENT")
        ~custom_value:(Some (`Assoc [ "attachment_id", `String "att_1"; "role", `String "assistant" ]))
        Custom )
  ; ( "projection.ml:203 run_started",
      make_event ~timestamp ~thread_id:thread ~run_id:(Some run) Run_started )
  ; ( "projection.ml:209 text_message_start",
      make_event ~timestamp ~thread_id:thread ~run_id:(Some run) ~message_id:(Some "m-1")
        ~role:(Some Assistant) Text_message_start )
  ; ( "projection.ml:215 text_message_content, response observed",
      make_event ~timestamp ~thread_id:thread ~run_id:(Some run) ~message_id:(Some "m-1")
        ~delta:(Some "Hello")
        ~text_response:(Observed_response { response_generation = 2; response_scope = 7 })
        Text_message_content )
  ; ( "projection.ml:215 text_message_content, scope only",
      make_event ~timestamp ~thread_id:thread ~run_id:(Some run) ~message_id:(Some "m-1")
        ~delta:(Some "Hello") ~text_response:(Unobserved_scope (Some 7)) Text_message_content )
  ; ( "projection.ml:215 text_message_content, no message_id or scope",
      make_event ~timestamp ~thread_id:thread ~run_id:None ~delta:(Some "") Text_message_content )
  ; ( "projection.ml:221 text_message_end",
      make_event ~timestamp ~thread_id:thread ~run_id:(Some run) ~message_id:(Some "m-1")
        Text_message_end )
  ; ( "projection.ml:221 text_message_end without message_id",
      make_event ~timestamp ~thread_id:thread ~run_id:(Some run) Text_message_end )
  ; ( "projection.ml:351 tool_call_start",
      tool_event ~tool_call_name:(Some "shell") Tool_call_start )
  ; ( "projection.ml:351 tool_call_start without tool_call_id or provider_message_id",
      tool_event ~tool_call_id:None ~provider_message_id:None ~tool_call_name:(Some "shell")
        Tool_call_start )
  ; ( "projection.ml:369 tool_call_args delta",
      tool_event ~delta:(Some "{\"cmd\":") Tool_call_args )
  ; ( "projection.ml:378 tool_call_args snapshot",
      tool_event ~snapshot:(Some (`String "{\"cmd\":\"ls\"}")) Tool_call_args )
  ; ( "projection.ml:387 tool_call_end", tool_event Tool_call_end )
  ; ( "projection.ml:471 run_error from an event error",
      make_event ~timestamp ~thread_id:thread ~run_id:(Some run) ~message:(Some "stream cut")
        ~code:(Some "event_error") Run_error )
  ; ( "projection.ml:479 run_finished",
      make_event ~timestamp ~thread_id:thread ~run_id:(Some run) Run_finished )
  ; ( "stream.ml:3434 synthesized terminal run_error",
      make_event ~timestamp ~thread_id:thread ~run_id:(Some run)
        ~message:(Some "the operation ended without a reply") ~code:(Some "operation_failed")
        Run_error )
  ; ( "agui.ml:124 prime run_started",
      make_event ~timestamp ~thread_id:default_thread_id ~run_id:(Some "session-1") Run_started )
  ; ( "agui.ml:10 MASC_EVENT",
      of_custom ~timestamp ~name:"MASC_EVENT" (`Assoc [ "type", `String "task_updated" ]) )
  ; ( "a whole-second timestamp",
      make_event ~timestamp:13.0 ~thread_id:thread ~run_id:(Some run) Run_finished )
  ]

(* JSON values with object keys compared as a set. *)
let rec normalize : Yojson.Safe.t -> Yojson.Safe.t = function
  | `Assoc fields ->
    `Assoc
      (List.sort (fun (a, _) (b, _) -> String.compare a b)
         (List.map (fun (key, value) -> key, normalize value) fields))
  | `List items -> `List (List.map normalize items)
  | other -> other

let json = Alcotest.testable Yojson.Safe.pretty_print Yojson.Safe.equal

let test_case (name, event) =
  Alcotest.test_case name `Quick (fun () ->
    let written = Yojson.Safe.to_string (Ag_ui.event_to_json event) in
    let frame = Wire_j.frame_of_string written in
    let rewritten = Wire_j.string_of_frame frame in
    Alcotest.check json "same JSON value"
      (normalize (Yojson.Safe.from_string written))
      (normalize (Yojson.Safe.from_string rewritten)))

(* The wire types refuse frames the server must not write. *)
let refuses name raw =
  Alcotest.test_case name `Quick (fun () ->
    match Wire_j.frame_of_string raw with
    | (_ : Wire_t.frame) -> Alcotest.failf "decoded %s" raw
    | exception Atdgen_runtime.Oj_run.Error _ -> ()
    | exception Yojson.Json_error _ -> ())

let refusals =
  [ refuses "TEXT_MESSAGE_CONTENT without delta"
      {|{"type":"TEXT_MESSAGE_CONTENT","threadId":"t","timestamp":1.0,"messageId":"m"}|}
  ; refuses "TOOL_CALL_START without toolCallName"
      {|{"type":"TOOL_CALL_START","threadId":"t","timestamp":1.0,"toolStreamScope":1,"toolCallBlockIndex":0}|}
  ; refuses "RUN_ERROR without message"
      {|{"type":"RUN_ERROR","threadId":"t","timestamp":1.0}|}
  ; refuses "a frame kind the server does not write"
      {|{"type":"STATE_SNAPSHOT","threadId":"t","timestamp":1.0}|}
  ]

let () =
  Alcotest.run "keeper_chat_wire_ag_ui"
    [ "server frames decode", List.map test_case cases; "refused frames", refusals ]
