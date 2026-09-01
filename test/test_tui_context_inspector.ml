open Alcotest

module Inspector = Masc_tui_context_inspector
open Turn_record

let turn_ref trace turn = Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:turn

let record ?(blocks = []) ?input_components ~trace ~turn () : Turn_record.t =
  { execution_ids = []
  ; keeper = "omega"
  ; agent_name = "keeper-omega"
  ; turn_kind = Direct
  ; trace_id = trace
  ; absolute_turn = turn
  ; turn_ref = turn_ref trace turn
  ; blocks
  ; input_components
  ; tool_surface_ref = None
  ; runtime_profile = "glm-coding"
  ; selected_model = Some "glm-5.3"
  ; finish_reason = Some "stop"
  ; context_window = Some 200_000
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = Some 1200
  ; ttfrc_ms = Some 80.
  ; request_wire_observation =
      Some { runtime_profile = "glm-coding"; body_bytes = 4096 }
  ; model_input_window =
      Some { transmitted_atoms = 3; total_atoms = 4; measurement = Wire_shape }
  ; raw_trace_run_ref = None
  ; sampling =
      { temperature = Some 0.2
      ; top_p = None
      ; max_tokens = None
      ; thinking_budget = None
      ; enable_thinking = Some true
      }
  ; usage =
      { input_tokens = Some 1000
      ; output_tokens = Some 200
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = Some 500
      ; scope = Runtime_usage_scope.Per_request
      }
  ; ts = 1_787_600_000.
  }

let envelope records =
  `Assoc
    [ ( "entries"
      , `List
          (List.map
             (fun record ->
                `Assoc
                  [ "record", Turn_record.to_json record
                  ; "diff_vs_prev", `Null
                  ])
             records) )
    ]

let test_newest_exact_composition_wins () =
  let observed =
    record ~trace:"trace-a" ~turn:1
      ~input_components:
        [ { component = Prompt_block Prompt_block_id.Dynamic_context
          ; bytes = 120
          }
        ; { component = Tool_schemas; bytes = 80 }
        ]
      ()
  in
  let unobserved = record ~trace:"trace-a" ~turn:2 () in
  match Inspector.decode_turn_records (envelope [ observed; unobserved ]) with
  | Error detail -> fail detail
  | Ok decoded ->
      check int "the latest row is the newest one, attributed or not" 2
        decoded.Inspector.latest.absolute_turn;
      (match decoded.Inspector.attributed with
       | None -> fail "an attributed row was on the page and must be reported"
       | Some attributed ->
           check int "attribution comes from the newest attributed row" 1
             attributed.Inspector.record.absolute_turn;
           check int "and the reading says how far back that row is" 1
             attributed.Inspector.turns_behind_latest;
           check int "attributed bytes" 200
             (List.fold_left
                (fun total (component : Turn_record.input_component) ->
                  total + component.bytes)
                0 attributed.Inspector.components))

(* On 2026-09-01 every row of rondo's and taskmaster's 50-turn page was
   unattributed, and the reading failed outright -- discarding the token,
   usage, wire and window readings the newest row did carry. *)
let test_page_without_attribution_still_reads () =
  let older = record ~trace:"trace-a" ~turn:7 () in
  let newer = record ~trace:"trace-a" ~turn:8 () in
  match Inspector.decode_turn_records (envelope [ older; newer ]) with
  | Error detail -> fail detail
  | Ok decoded ->
      check int "the latest row is still reported" 8
        decoded.Inspector.latest.absolute_turn;
      check bool "with no attribution to show" true
        (Option.is_none decoded.Inspector.attributed)

let test_empty_page_is_an_error () =
  check bool "an empty page has no latest row to report" true
    (Result.is_error (Inspector.decode_turn_records (envelope [])))

let test_malformed_row_is_not_dropped () =
  let good = record ~trace:"trace-a" ~turn:1 ~input_components:[] () in
  let json =
    match envelope [ good ] with
    | `Assoc [ "entries", `List rows ] ->
      `Assoc [ "entries", `List (`Assoc [ "diff_vs_prev", `Null ] :: rows) ]
    | _ -> fail "fixture shape changed"
  in
  check bool "malformed row fails the whole reading" true
    (Result.is_error (Inspector.decode_turn_records json))

let digest text = Digestif.SHA256.(digest_string text |> to_hex)

let wire =
  Llm_provider.Request_wire_observer.observation
    ~capture_id:(Some "capture-1")
    ~provider:"glm"
    ~model:"glm-5.3"
    ~http_codec:"openai_chat"
    ~stream:true
    ~body:"serialized provider body"

let provider_input_response ?(keeper = "omega") ?(trace = "trace-map")
    ?(turn = 9) system_prompt =
  let message_content =
    `Assoc
      [ "role", `String "tool"
      ; ( "content_blocks"
        , `List
            [ `Assoc
                [ "type", `String "tool_result"
                ; "tool_use_id", `String "call-1"
                ; "content", `String "large result"
                ; "is_error", `Bool false
                ]
            ] )
      ]
  in
  let tool_content =
    `Assoc
      [ "name", `String "masc_execute"
      ; "description", `String "Execute one command"
      ; "input_schema", `Assoc [ "type", `String "object" ]
      ]
  in
  `Assoc
    [ "dashboard_surface", `String "/api/v1/keepers/:name/provider-input"
    ; "schema", `String "masc.resolved-provider-input.v1"
    ; "keeper", `String keeper
    ; "trace_id", `String trace
    ; "absolute_turn", `Int turn
    ; "turn_ref", Ids.Turn_ref.to_yojson (turn_ref trace turn)
    ; "runtime_profile", `String "glm-coding"
    ; "captured_at", `Float 1_787_600_000.
    ; "wire", Llm_provider.Request_wire_observer.observation_to_yojson wire
    ; ( "system_prompt"
      , `Assoc
          [ "bytes", `Int (String.length system_prompt)
          ; "sha256", `String (digest system_prompt)
          ; "text", `String system_prompt
          ] )
    ; ( "messages"
      , `List
          [ `Assoc
              [ "index", `Int 0
              ; "role", `String "tool"
              ; "bytes", `Int 160
              ; "sha256", `String (String.make 64 'a')
              ; "content", message_content
              ]
          ] )
    ; ( "tool_schemas"
      , `List
          [ `Assoc
              [ "index", `Int 0
              ; "name", `String "masc_execute"
              ; "bytes", `Int 120
              ; "sha256", `String (String.make 64 'b')
              ; "content", tool_content
              ]
          ] )
    ]

let decode_provider_input system_prompt =
  Inspector.decode_provider_input
    ~expected_keeper:"omega"
    ~expected_turn_ref:(turn_ref "trace-map" 9)
    (provider_input_response system_prompt)

let test_provider_input_is_bound_to_exact_turn () =
  let system_prompt = "immutable keeper instructions" in
  match decode_provider_input system_prompt with
  | Error detail -> fail detail
  | Ok input ->
    check string "exact turn ref" "trace-map#9"
      (Ids.Turn_ref.to_string input.turn_ref);
    check int "system + message + tool" 3
      (List.length (Inspector.exact_input_items input));
    check string "wire digest survives" wire.body_sha256 input.wire.body_sha256;
    check string "tool result is openable" "Message · tool"
      (Inspector.exact_input_label
         (List.nth (Inspector.exact_input_items input) 1).kind)

let test_provider_input_rejects_another_keeper_or_turn () =
  let system_prompt = "immutable keeper instructions" in
  check bool "wrong keeper rejected" true
    (Result.is_error
       (Inspector.decode_provider_input
          ~expected_keeper:"omega"
          ~expected_turn_ref:(turn_ref "trace-map" 9)
          (provider_input_response ~keeper:"other" system_prompt)));
  check bool "wrong turn rejected" true
    (Result.is_error
       (Inspector.decode_provider_input
          ~expected_keeper:"omega"
          ~expected_turn_ref:(turn_ref "trace-map" 9)
          (provider_input_response ~turn:10 system_prompt)))

let test_input_map_opens_only_digest_verified_system_prompt () =
  let system_prompt = "immutable keeper instructions" in
  let block =
    { block = Prompt_block_id.Keeper_instructions
    ; bytes = String.length system_prompt
    ; digest = digest system_prompt
    }
  in
  let observed =
    record ~trace:"trace-map" ~turn:9 ~blocks:[ block ]
      ~input_components:
        [ { component = Prompt_block Prompt_block_id.Keeper_instructions
          ; bytes = String.length system_prompt
          }
        ; { component = Message_tool_result; bytes = 12 }
        ]
      ()
  in
  let input =
    match decode_provider_input system_prompt with
    | Ok input -> input
    | Error detail -> fail detail
  in
  let rows = Inspector.input_map_rows observed (Some input) in
  check (option string) "system prompt verified" (Some system_prompt)
    (List.nth rows 0).exact_text;
  check string "message points to exact input tab" "exact items in input tab"
    (List.nth rows 1).retention;
  let changed =
    { observed with blocks = [ { block with digest = digest "other" } ] }
  in
  check (option string) "digest mismatch is not opened" None
    (List.hd (Inspector.input_map_rows changed (Some input))).exact_text

let test_a_size_never_outgrows_the_column_it_is_drawn_in () =
  List.iter
    (fun bytes ->
       let text = Inspector.format_bytes bytes in
       check bool
         (Printf.sprintf "%d bytes reads as %s, within nine cells" bytes text)
         true
         (String.length text <= 9))
    [ 0
    ; 1
    ; 999
    ; 1023
    ; 1024
    ; 1_048_575
    ; 1_048_576
    ; 999_999_999
    ; 1_073_741_824
    ]

let test_a_size_climbs_past_kilobytes () =
  List.iter
    (fun (bytes, expected) ->
       check string (Printf.sprintf "%d bytes" bytes) expected
         (Inspector.format_bytes bytes))
    [ 512, "512 B"
    ; 1024, "1.0 KB"
    ; 1_048_576, "1.0 MB"
    ; 3_145_728, "3.0 MB"
    ]

let test_a_tool_schema_is_grouped_with_the_other_schemas () =
  (* [exact_input_label] names a schema after its tool, which would put every
     schema in a group of one. The summary needs them counted together: on a
     real turn the schemas are the second-largest thing in the request. *)
  Alcotest.(check string)
    "schemas share one group" "Tool schemas"
    (Inspector.exact_input_category (Inspector.Tool_schema { name = "masc_check" }));
  Alcotest.(check string)
    "and it does not depend on the tool" "Tool schemas"
    (Inspector.exact_input_category (Inspector.Tool_schema { name = "masc_tasks" }));
  (* Messages stay split by role, which is what separates a tool result from
     the assistant text that called for it. *)
  Alcotest.(check string)
    "a tool result" "Message · tool"
    (Inspector.exact_input_category (Inspector.Message { role = "tool" }));
  Alcotest.(check string)
    "an assistant message" "Message · assistant"
    (Inspector.exact_input_category (Inspector.Message { role = "assistant" }));
  Alcotest.(check string)
    "the system prompt" "System prompt"
    (Inspector.exact_input_category Inspector.System_prompt)

let () =
  run "tui_context_inspector"
    [ ( "decode"
      , [ test_case "selects newest exact composition" `Quick
            test_newest_exact_composition_wins
        ; test_case "an unattributed page still reads" `Quick
            test_page_without_attribution_still_reads
        ; test_case "an empty page is an error" `Quick
            test_empty_page_is_an_error
        ; test_case "rejects malformed rows" `Quick
            test_malformed_row_is_not_dropped
        ; test_case "binds provider input to exact turn" `Quick
            test_provider_input_is_bound_to_exact_turn
        ; test_case "rejects another keeper or turn" `Quick
            test_provider_input_rejects_another_keeper_or_turn
        ; test_case "opens only digest-verified system prompt" `Quick
            test_input_map_opens_only_digest_verified_system_prompt
        ; test_case "a size never outgrows its column" `Quick
            test_a_size_never_outgrows_the_column_it_is_drawn_in
        ; test_case "a size climbs past kilobytes" `Quick
            test_a_size_climbs_past_kilobytes
        ; test_case "a tool schema is grouped with the other schemas" `Quick
            test_a_tool_schema_is_grouped_with_the_other_schemas
        ] )
    ]
