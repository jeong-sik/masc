(* RFC-0510 §1.1: the cases of the table there, one test each. The function
   under test reads the message list only, so every fixture is a list built
   here and no store, clock or config is involved. *)

open Alcotest
module Stub = Masc.Keeper_same_turn_result_stub
module Types = Agent_core.Types

let floor = 2_048
let tool = "masc_board_post_get"
let on name = String.equal name tool
let body fill = String.make floor fill

let turn_start text : Types.message =
  Types.make_message ~origin:Types.Conversation ~role:Types.User [ Types.text_block text ]
;;

let call ?(name = tool) id : Types.message =
  Types.make_message ~role:Types.Assistant [ Types.ToolUse { id; name; input = `Assoc [] } ]
;;

let result id content : Types.message = Types.tool_result_msg ~tool_use_id:id ~content ()

let result_block id content : Types.content_block =
  Types.ToolResult
    { tool_use_id = id
    ; content
    ; outcome = Types.Tool_succeeded
    ; json = None
    ; content_blocks = None
    }
;;

let contents (messages : Types.message list) =
  List.concat_map
    (fun (message : Types.message) ->
       List.filter_map
         (fun (block : Types.content_block) ->
            match block with
            | Types.ToolResult { content; _ } -> Some content
            | Types.Text _
            | Types.Thinking _
            | Types.ReasoningDetails _
            | Types.RedactedThinking _
            | Types.ToolUse _ | Types.ToolReference _
            | Types.Image _
            | Types.Document _
            | Types.Audio _ -> None)
         message.content)
    messages
;;

let stub_of ~first text =
  Stub.encode
    ~first_tool_use_id:first
    ~bytes:(String.length text)
    ~sha256:Agent_core_sha256.(digest_string text |> to_hex)
;;

let apply messages = Stub.apply ~enabled:on ~min_bytes:floor messages
let check_contents label expected messages = check (list string) label expected (contents messages)

let two_equal () =
  let a = body 'a' in
  check_contents
    "first stays, second is the stub"
    [ a; stub_of ~first:"t1" a ]
    (apply [ turn_start "go"; call "t1"; result "t1" a; call "t2"; result "t2" a ])
;;

let three_equal () =
  let a = body 'a' in
  check_contents
    "second and third both name the first"
    [ a; stub_of ~first:"t1" a; stub_of ~first:"t1" a ]
    (apply
       [ turn_start "go"
       ; call "t1"
       ; result "t1" a
       ; call "t2"
       ; result "t2" a
       ; call "t3"
       ; result "t3" a
       ])
;;

let one_byte_differs () =
  let a = body 'a' in
  let b = String.sub a 0 (floor - 1) ^ "b" in
  let messages = [ turn_start "go"; call "t1"; result "t1" a; call "t2"; result "t2" b ] in
  check bool "the input list is returned" true (apply messages == messages)
;;

let under_the_floor () =
  let small = String.make (floor - 1) 'a' in
  let messages =
    [ turn_start "go"; call "t1"; result "t1" small; call "t2"; result "t2" small ]
  in
  check bool "the input list is returned" true (apply messages == messages)
;;

let earlier_turn_is_not_named () =
  let a = body 'a' in
  let messages =
    [ turn_start "one"
    ; call "t1"
    ; result "t1" a
    ; turn_start "two"
    ; call "t2"
    ; result "t2" a
    ]
  in
  check bool "the input list is returned" true (apply messages == messages)
;;

let two_blocks_in_one_message () =
  let a = body 'a' in
  let both : Types.message =
    Types.make_message ~role:Types.Tool [ result_block "t1" a; result_block "t2" a ]
  in
  check_contents
    "the front block stays, the back block is the stub"
    [ a; stub_of ~first:"t1" a ]
    (apply [ turn_start "go"; call "t1"; call "t2"; both ])
;;

let tool_is_off () =
  let a = body 'a' in
  let messages =
    [ turn_start "go"
    ; call ~name:"Execute" "t1"
    ; result "t1" a
    ; call ~name:"Execute" "t2"
    ; result "t2" a
    ]
  in
  check bool "the input list is returned" true (apply messages == messages)
;;

let unknown_tool () =
  let a = body 'a' in
  let messages = [ turn_start "go"; result "t1" a; result "t2" a ] in
  check bool "a result with no call in front of it stays" true (apply messages == messages)
;;

let media_in_the_message () =
  let a = body 'a' in
  let with_image : Types.message =
    Types.make_message
      ~role:Types.Tool
      [ result_block "t2" a
      ; Types.image_block ~media_type:"image/png" ~source:(Types.Url "https://example.invalid/a.png")
      ]
  in
  let messages = [ turn_start "go"; call "t1"; result "t1" a; call "t2"; with_image ] in
  check bool "the input list is returned" true (apply messages == messages)
;;

let stub_stays_after_the_turn () =
  let a = body 'a' in
  let turn_one = [ turn_start "one"; call "t1"; result "t1" a; call "t2"; result "t2" a ] in
  let during = apply turn_one in
  let after = apply (turn_one @ [ turn_start "two"; call "t3"; result "t3" (body 'b') ]) in
  check_contents "the stub of turn one is still the same stub" (contents during @ [ body 'b' ]) after
;;

let first_result_is_gone () =
  let a = body 'a' in
  let one_left = [ call "t2"; result "t2" a ] in
  check bool "the remaining result goes as it is" true (apply one_left == one_left);
  check_contents
    "with two left, the front one is the first"
    [ a; stub_of ~first:"t2" a ]
    (apply (one_left @ [ call "t3"; result "t3" a ]))
;;

let same_input_same_output () =
  let a = body 'a' in
  let messages = [ turn_start "go"; call "t1"; result "t1" a; call "t2"; result "t2" a ] in
  check_contents "two runs agree" (contents (apply messages)) (apply messages);
  check_contents "a run over its own output changes nothing" (contents (apply messages)) (apply (apply messages))
;;

let appending_keeps_the_front () =
  let a = body 'a' in
  let front = [ turn_start "go"; call "t1"; result "t1" a; call "t2"; result "t2" a ] in
  let longer = front @ [ call "t3"; result "t3" a; turn_start "next"; call "t4"; result "t4" a ] in
  let front_out = contents (apply front) in
  let longer_out = contents (apply longer) in
  check
    (list string)
    "the output for the front is a prefix of the longer output"
    front_out
    (List.filteri (fun index _ -> index < List.length front_out) longer_out)
;;

let stub_keeps_the_call_id () =
  let a = body 'a' in
  let out =
    apply
      [ turn_start "go"; call "t1"; result "t1" "{}"; call "t2"; result "t2" a; call "t3"; result "t3" a ]
  in
  let ids_and_json =
    List.concat_map
      (fun (message : Types.message) ->
         List.filter_map
           (fun (block : Types.content_block) ->
              match block with
              | Types.ToolResult { tool_use_id; json; _ } -> Some (tool_use_id, Option.is_some json)
              | Types.Text _
              | Types.Thinking _
              | Types.ReasoningDetails _
              | Types.RedactedThinking _
              | Types.ToolUse _ | Types.ToolReference _
              | Types.Image _
              | Types.Document _
              | Types.Audio _ -> None)
           message.content)
      out
  in
  check
    (list (pair string bool))
    "each result keeps its own id; the stub carries no parsed payload"
    [ "t1", true; "t2", false; "t3", false ]
    ids_and_json
;;

let () =
  run
    "keeper_same_turn_result_stub"
    [ ( "rfc-0510 §1.1"
      , [ test_case "two equal results" `Quick two_equal
        ; test_case "three equal results" `Quick three_equal
        ; test_case "one byte differs" `Quick one_byte_differs
        ; test_case "under the floor" `Quick under_the_floor
        ; test_case "same text in the earlier turn" `Quick earlier_turn_is_not_named
        ; test_case "two blocks of one message" `Quick two_blocks_in_one_message
        ; test_case "tool is off" `Quick tool_is_off
        ; test_case "tool is unknown" `Quick unknown_tool
        ; test_case "media in the message" `Quick media_in_the_message
        ; test_case "stub stays after the turn" `Quick stub_stays_after_the_turn
        ; test_case "first result is gone" `Quick first_result_is_gone
        ; test_case "same input, same output" `Quick same_input_same_output
        ; test_case "appending keeps the front" `Quick appending_keeps_the_front
        ; test_case "stub keeps the call id" `Quick stub_keeps_the_call_id
        ] )
    ]
;;
