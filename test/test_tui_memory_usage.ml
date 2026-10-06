open Alcotest
module Usage = Masc_tui_memory_usage
open Turn_record

let turn_ref trace turn = Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:turn

let record ?(blocks = []) ?input_components ?(usage_scope = Runtime_usage_scope.Per_request)
    ~trace ~turn () : Turn_record.t =
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
  ; provider_context_window = None
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = Some 1200
  ; ttfrc_ms = Some 80.
  ; request_wire_observation =
      Some { runtime_profile = "glm-coding"; body_bytes = 4096 }
  ; model_input_window =
      Some
        { transmitted_atoms = 3
        ; total_atoms = 4
        ; measurement = Wire_shape
        ; model_input_front = Model_input_front.At_atom (String.make 64 'c')
        }
  ; response_observed_model_input = None
  ; raw_trace_run_ref = None
  ; sampling =
      { temperature = Some 0.2
      ; top_p = None
      ; max_tokens = None
      ; enable_thinking = Some true
      }
  ; usage =
      { input_tokens = Some 1000
      ; output_tokens = Some 200
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = Some 500
      ; scope = usage_scope
      }
  ; turn_output_tokens = None
  ; ts = 1_787_600_000.
  }

let page ?(skipped = 0) records =
  `Assoc
    [ "keeper", `String "omega"
    ; "skipped_rows", `Int skipped
    ; "entries", `List (List.map (fun r -> `Assoc ["record", Turn_record.to_json r]) records)
    ]

let read records =
  match Usage.decode ~keeper:"omega" (page records) with
  | Ok value -> value
  | Error reason -> fail reason

let sample turn scope tokens bytes =
  let base = record ~trace:"trace-memory" ~turn ~usage_scope:scope () in
  { base with usage = { base.usage with input_tokens = tokens };
    request_wire_observation = Option.map (fun body_bytes ->
      { Turn_record.runtime_profile = base.runtime_profile; body_bytes }) bytes }

let test_mixed_coverage_and_latest () =
  let snapshot = read
      [ sample 1 Per_request (Some 1000) (Some 1024)
      ; sample 2 Per_request (Some 0) (Some 2048)
      ; sample 3 Per_request (Some 5000) None
      ; sample 4 Conversation_cumulative (Some 900000) (Some 3072)
      ; sample 5 Turn_total (Some 60000) None
      ; sample 6 Usage_scope_unavailable (Some 80000) None
      ; sample 7 Per_request None (Some 8192)
      ] in
  check int "all seven recorded turns are the window" 7 snapshot.records;
  let tokens = Option.get snapshot.tokens.distribution in
  check int "only request-scoped reported values, including zero" 3 tokens.samples;
  check (float 0.001) "arithmetic mean" 2000. tokens.mean;
  check int "maximum" 5000 tokens.maximum;
  check int "reported zero minimum" 0 tokens.minimum;
  check (option int) "missing latest is not an older reported value" None snapshot.tokens.last;
  let bytes = Option.get snapshot.bytes.distribution in
  check int "wire coverage is independent of token scope" 4 bytes.samples;
  check (float 0.001) "byte mean" 3584. bytes.mean;
  check (option int) "latest byte observation remains available" (Some 8192) snapshot.bytes.last

let test_zero_and_empty () =
  let empty = read [] in
  check int "empty page" 0 empty.records;
  check bool "empty does not invent a zero mean" true (empty.tokens.distribution = None);
  let zero = read [sample 1 Per_request (Some 0) (Some 0)] in
  check (option int) "zero is a reported last input" (Some 0) zero.tokens.last;
  check (float 0.) "zero mean" 0. (Option.get zero.tokens.distribution).mean

let test_refuses_partial_or_other_keeper () =
  let r = sample 1 Per_request (Some 1000) (Some 1024) in
  List.iter (fun json ->
    match Usage.decode ~keeper:"omega" json with
    | Error _ -> ()
    | Ok _ -> fail "partial or misattributed page became current statistics")
    [ page ~skipped:1 [r]
    ; page [{r with keeper = "another"}]
    ; `Assoc ["keeper", `String "omega"; "entries", `List []]
    ; `Assoc ["keeper", `String "another"; "skipped_rows", `Int 0; "entries", `List []]
    ; `Assoc ["keeper", `String "omega"; "skipped_rows", `Int 0;
              "entries", `List [`Assoc ["record", `Assoc []]]]
    ]

let () =
  run "Memory input observations"
    [ "request statistics",
      [ test_case "mixed coverage and missing latest" `Quick test_mixed_coverage_and_latest
      ; test_case "zero and empty" `Quick test_zero_and_empty
      ; test_case "refuse partial or misattributed pages" `Quick test_refuses_partial_or_other_keeper
      ] ]
