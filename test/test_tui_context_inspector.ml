open Alcotest

module Inspector = Masc_tui_context_inspector
open Turn_record

let turn_ref trace turn =
  match Ids.Turn_ref.of_yojson (`String (Printf.sprintf "%s#%d" trace turn)) with
  | Ok value -> value
  | Error detail -> fail detail

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

let digest text = Digestif.SHA256.(digest_string text |> to_hex)

let test_input_map_joins_only_verified_prompt_text () =
  let text = "remember the operator preference" in
  let prompt_block : Turn_record.prompt_block =
    { block = Prompt_block_id.Memory_os_recall
    ; bytes = String.length text
    ; digest = digest text
    }
  in
  let observed =
    record ~trace:"trace-map" ~turn:9 ~blocks:[ prompt_block ]
      ~input_components:
        [ { component = Prompt_block Prompt_block_id.Memory_os_recall
          ; bytes = String.length text
          }
        ; { component = Tool_schemas; bytes = 2048 }
        ]
      ()
  in
  let capture : Masc.Keeper_prompt_capture.capture =
    { captured_at = 1_787_600_000.
    ; trace_id = "trace-map"
    ; absolute_turn = 9
    ; blocks = [ { id = Prompt_block_id.Memory_os_recall; text } ]
    ; assembled = Some text
    }
  in
  let rows = Inspector.input_map_rows observed (Some capture) in
  let memory = List.nth rows 0 in
  let tools = List.nth rows 1 in
  check (option string) "matching capture exposes exact text" (Some text)
    memory.exact_text;
  check string "matching capture is verified" "verified exact text"
    memory.retention;
  check (option string) "tool schemas stay byte-only" None tools.exact_text;
  check string "tool source is explicit" "effective tool surface"
    tools.included_by;
  let stale = { capture with absolute_turn = 8 } in
  let stale_memory = List.hd (Inspector.input_map_rows observed (Some stale)) in
  check (option string) "another turn is not joined" None stale_memory.exact_text;
  let changed =
    { capture with
      blocks =
        [ { id = Prompt_block_id.Memory_os_recall
          ; text = "different text with same authority"
          }
        ]
    }
  in
  let changed_memory =
    List.hd (Inspector.input_map_rows observed (Some changed))
  in
  check (option string) "digest mismatch is not joined" None
    changed_memory.exact_text

(* Three surfaces spell a byte count through this: the Context inspector, the
   attachment note beside a chat message, and the skill-delivery row. The
   delivery row used to divide by 1024 itself and so had no rung above KB.

   A column has to hold the widest reading, and the widest is not the largest
   number: [1023.9 KB] is nine cells while [999.9 MB] is eight. The delivery
   column is sized nine, so that is what this pins. *)
let test_a_size_never_outgrows_the_column_it_is_drawn_in () =
  List.iter
    (fun bytes ->
      let text = Masc_tui_context_inspector.format_bytes bytes in
      check bool
        (Printf.sprintf "%d bytes reads as %s, within nine cells" bytes text)
        true
        (String.length text <= 9))
    [ 0; 1; 999; 1023; 1024; 1_048_575; 1_048_576; 999_999_999;
      1_073_741_824 ]

let test_a_size_climbs_past_kilobytes () =
  List.iter
    (fun (bytes, expected) ->
      check string (Printf.sprintf "%d bytes" bytes) expected
        (Masc_tui_context_inspector.format_bytes bytes))
    [ (512, "512 B")
    ; (1024, "1.0 KB")
    ; (1_048_576, "1.0 MB")
    ; (3_145_728, "3.0 MB")
    ]

let () =
  run "tui_context_inspector"
    [ ( "decode"
      , [ test_case "selects newest exact composition" `Quick
            test_newest_exact_composition_wins
        ; test_case "rejects malformed rows" `Quick
            test_malformed_row_is_not_dropped
        ; test_case "binds exact prompt to Keeper" `Quick
            test_prompt_capture_binds_keeper
        ; test_case "joins only verified prompt text" `Quick
            test_input_map_joins_only_verified_prompt_text
        ; test_case "a size never outgrows its column" `Quick
            test_a_size_never_outgrows_the_column_it_is_drawn_in
        ; test_case "a size climbs past kilobytes" `Quick
            test_a_size_climbs_past_kilobytes
        ] )
    ]
