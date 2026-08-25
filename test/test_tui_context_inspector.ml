open Alcotest

module Inspector = Masc_tui_context_inspector
open Turn_record

let turn_ref trace turn =
  match Ids.Turn_ref.of_yojson (`String (Printf.sprintf "%s#%d" trace turn)) with
  | Ok value -> value
  | Error detail -> fail detail

let record ?input_components ~trace ~turn () : Turn_record.t =
  { execution_ids = []
  ; keeper = "omega"
  ; agent_name = "keeper-omega"
  ; turn_kind = Direct
  ; trace_id = trace
  ; absolute_turn = turn
  ; turn_ref = turn_ref trace turn
  ; blocks = []
  ; input_components
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
      check int "newest row with exact attribution" 1 decoded.absolute_turn;
      check (option int) "attributed bytes" (Some 200)
        (Inspector.attributed_bytes decoded)

let test_malformed_row_is_not_dropped () =
  let good = record ~trace:"trace-a" ~turn:1 ~input_components:[] () in
  let json =
    match envelope [ good ] with
    | `Assoc [ ("entries", `List rows) ] ->
        `Assoc
          [ ( "entries"
            , `List
                (`Assoc [ "diff_vs_prev", `Null ] :: rows) ) ]
    | _ -> fail "fixture shape changed"
  in
  check bool "malformed row fails the whole reading" true
    (Result.is_error (Inspector.decode_turn_records json))

let prompt_response keeper =
  let capture : Masc.Keeper_prompt_capture.capture =
    { captured_at = 1_787_600_000.
    ; trace_id = "trace-a"
    ; absolute_turn = 7
    ; blocks =
        [ { id = Prompt_block_id.Memory_os_recall
          ; text = "Remember the exact fact."
          }
        ]
    ; assembled = Some "Remember the exact fact."
    }
  in
  match Masc.Keeper_prompt_capture.to_json capture with
  | `Assoc fields -> `Assoc (("keeper", `String keeper) :: fields)
  | _ -> fail "capture encoder did not return an object"

let test_prompt_capture_binds_keeper () =
  check bool "wrong Keeper is rejected" true
    (Result.is_error
       (Inspector.decode_prompt_capture ~expected_keeper:"omega"
          (prompt_response "other")));
  match
    Inspector.decode_prompt_capture ~expected_keeper:"omega"
      (prompt_response "omega")
  with
  | Error detail -> fail detail
  | Ok capture ->
      check int "one exact prompt block" 1 (List.length capture.blocks);
      check string "memory label" "Memory recall"
        (Inspector.prompt_block_label (List.hd capture.blocks).id)

let () =
  run "tui_context_inspector"
    [ ( "decode"
      , [ test_case "selects newest exact composition" `Quick
            test_newest_exact_composition_wins
        ; test_case "rejects malformed rows" `Quick
            test_malformed_row_is_not_dropped
        ; test_case "binds exact prompt to Keeper" `Quick
            test_prompt_capture_binds_keeper
        ] )
    ]
