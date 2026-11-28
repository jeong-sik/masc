(* The AG-UI frames the server writes today decode into the keeper_chat_wire
   types, and writing the decoded value back gives the same JSON value.

   Each case builds an event with one Ag_ui constructor and one option
   combination a call site passes, encodes it with the server's encoder
   (Ag_ui.event_to_json), and reads it with the atd-generated reader. The
   comparison is on JSON values: object key order is not part of the wire. *)

module Wire_j = Keeper_chat_wire.Keeper_chat_wire_j
module Wire_t = Keeper_chat_wire.Keeper_chat_wire_t

let cases = Agui_frame_cases.cases
let normalize = Agui_frame_cases.normalize

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
