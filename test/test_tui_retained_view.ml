(* What the context inspector's detail column reads, split by what each part
   is. The fixtures are built with the same encoder the wire uses rather
   than hand-copied JSON, so a wire shape change breaks the round trip here
   instead of silently drifting past a copied fixture. *)

module Types = Agent_core.Types
module View = Masc_tui_retained_view

let check = Alcotest.check
let sections_ty = Alcotest.list Alcotest.string

let show = function
  | View.Text t -> "T " ^ t
  | View.Json j -> "J " ^ j
  | View.Marker m -> "M " ^ m

let shown ~text = View.sections ~text |> List.map show

(* A message row's wire JSON: content_blocks under their field, the shape
   [content_blocks_of_json] reads. *)
let message_text blocks =
  `Assoc
    [ ( "content_blocks"
      , Masc.Keeper_context_core_message_json.content_blocks_to_json blocks ) ]
  |> Yojson.Safe.to_string

let test_plain_text_stays_text () =
  check sections_ty "text that is not JSON stays one Text section"
    [ "T 지금은 자율 턴입니다." ]
    (shown ~text:"지금은 자율 턴입니다.")

let test_malformed_json_stays_text () =
  check sections_ty "malformed JSON is prose rather than a crashed detail pane"
    [ "T {\"content_blocks\":[" ]
    (shown ~text:"{\"content_blocks\":[")

let test_json_without_blocks_stays_json () =
  check sections_ty "a schema row keeps its payload whole"
    [ "J {\"type\":\"object\"}" ]
    (shown ~text:"{\"type\":\"object\"}")

let test_a_text_block_reads_as_prose () =
  let text = message_text [ Types.Text "무엇을 읽을지 먼저 정합니다." ] in
  check sections_ty "a text block becomes its text"
    [ "T 무엇을 읽을지 먼저 정합니다." ]
    (shown ~text)

let test_a_tool_use_names_itself_and_carries_its_input () =
  let input = `Assoc [ ("path", `String "/tmp/a") ] in
  let text =
    message_text
      [ Types.ToolUse { id = "call-1"; name = "read_file"; input } ]
  in
  check sections_ty "a tool use is a marker and its pretty input"
    [ "M tool use read_file"; "J " ^ Yojson.Safe.pretty_to_string input ]
    (shown ~text)

let test_a_tool_result_reads_its_content_and_payload () =
  let payload = `Assoc [ ("lines", `Int 12) ] in
  let text =
    message_text
      [ Types.ToolResult
          { tool_use_id = "call-1"; content = "12 lines read"
          ; outcome = Types.Tool_succeeded
          ; json = Some payload
          ; content_blocks = None
          }
      ]
  in
  check sections_ty "a tool result is a marker, its text, and its payload"
    [ "M tool result"; "T 12 lines read"
    ; "J " ^ Yojson.Safe.pretty_to_string payload
    ]
    (shown ~text)

let test_a_failed_tool_result_says_so () =
  let text =
    message_text
      [ Types.ToolResult
          { tool_use_id = "call-2"; content = "connection refused"
          ; outcome =
              Types.Tool_failed
                { failure_kind = Types.Recoverable_tool_error
                ; error_class = None
                }
          ; json = None
          ; content_blocks = None
          }
      ]
  in
  check sections_ty "the marker names the error outcome"
    [ "M tool result (error)"; "T connection refused" ]
    (shown ~text)

let test_an_image_states_its_size () =
  let text =
    message_text
      [ Types.Image
          { media_type = "image/png"; data = String.make 100 'x'
          ; source_type = Types.Base64
          }
      ]
  in
  check sections_ty "an image is a marker with its byte count"
    [ "M image image/png, 100 bytes" ]
    (shown ~text)

let () =
  Alcotest.run "tui_retained_view"
    [ ( "sections"
      , [ Alcotest.test_case "plain text stays text" `Quick
            test_plain_text_stays_text
        ; Alcotest.test_case "json without blocks stays json" `Quick
            test_json_without_blocks_stays_json
        ; Alcotest.test_case "malformed JSON stays text" `Quick
            test_malformed_json_stays_text
        ; Alcotest.test_case "a text block reads as prose" `Quick
            test_a_text_block_reads_as_prose
        ; Alcotest.test_case "a tool use names itself and carries its input"
            `Quick test_a_tool_use_names_itself_and_carries_its_input
        ; Alcotest.test_case "a tool result reads its content and payload"
            `Quick test_a_tool_result_reads_its_content_and_payload
        ; Alcotest.test_case "a failed tool result says so" `Quick
            test_a_failed_tool_result_says_so
        ; Alcotest.test_case "an image states its size" `Quick
            test_an_image_states_its_size
        ] )
    ]
